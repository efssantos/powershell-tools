<#
.SYNOPSIS
    Backup profissional de perfil Windows para formatação e migração.

.DESCRIPTION
    V2 - ferramenta de Help Desk para inventário, backup, validação e relatório.

    Compatível com Windows PowerShell 5.1+ / Windows 10 e Windows 11.

    Recursos:
      - Inventário do computador, usuário e Windows
      - Inventário de impressoras e unidades de rede
      - Análise de tamanho das pastas
      - Verificação de espaço no destino
      - Backup seletivo de dados pessoais
      - Outlook: assinaturas e PST
      - Chrome e Edge: favoritos de todos os perfis
      - Sticky Notes
      - OneDrive: arquivos locais do perfil (sem copiar cache)
      - Wi-Fi opcional
      - Exclusão de caches e temporários
      - Detecção de arquivos grandes
      - Robocopy com logs e códigos de retorno
      - Manifesto JSON
      - Relatório HTML
      - Validação pós-backup por contagem/tamanho
      - SHA256 opcional para arquivos críticos
      - WhatIf
      - Status de execução e códigos de saída

    IMPORTANTE:
      - O script NÃO copia AppData inteiro.
      - OST não é copiado: normalmente pode ser recriado pelo Outlook.
      - Wi-Fi com key=clear deve ser usado somente quando necessário, pois
        os XMLs podem conter chaves de rede.

.EXAMPLE
    .\Backup-UserProfile-v3.ps1 -DestinationPath "D:\Backups"

.EXAMPLE
    .\Backup-UserProfile-v3.ps1 -DestinationPath "\\SRV-FS01\Migracao" `
        -UserName "joao.silva" -IncludeDownloads -IncludeMedia `
        -IncludeWifi -Validate -HashCriticalFiles

.EXAMPLE
    .\Backup-UserProfile-v3.ps1 -DestinationPath "D:\Backups" -Mode Inventory

.NOTES
    Versão: 3.0
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$DestinationPath,

    [Parameter()]
    [string]$UserName = $env:USERNAME,

    [Parameter()]
    [ValidateSet('Backup','Inventory')]
    [string]$Mode = 'Backup',

    [Parameter()]
    [switch]$IncludeDownloads,

    [Parameter()]
    [switch]$IncludeMedia,

    [Parameter()]
    [switch]$IncludeWifi,

    [Parameter()]
    [switch]$IncludeCertificates,

    [Parameter()]
    [switch]$Validate,

    [Parameter()]
    [switch]$HashCriticalFiles,

    [Parameter()]
    [switch]$IncludeLargeFilesReport,

    [Parameter()]
    [ValidateRange(1, 32)]
    [int]$Threads = 8,

    [Parameter()]
    [ValidateRange(0, 10)]
    [int]$RetryCount = 2,

    [Parameter()]
    [ValidateRange(0, 30)]
    [int]$WaitSeconds = 2,

    [Parameter()]
    [ValidateRange(100, 10240)]
    [int]$LargeFileThresholdMB = 1024
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptVersion = '3.0'
$ComputerName = $env:COMPUTERNAME
$StartTime = Get-Date
$Timestamp = $StartTime.ToString('yyyyMMdd_HHmmss')
$Results = [System.Collections.Generic.List[object]]::new()
$Inventory = [ordered]@{}
$UserProfilePath = $null
$TargetBackupDir = $null
$LogFile = $null
$RobocopyLog = $null

function Write-Console {
    param([string]$Message,[ConsoleColor]$Color = [ConsoleColor]::White)
    Write-Host $Message -ForegroundColor $Color
}

function Write-Log {
    param([string]$Message,[ConsoleColor]$Color = [ConsoleColor]::Gray)
    $Line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    if ($LogFile) { Add-Content -LiteralPath $LogFile -Value $Line -Encoding UTF8 }
    Write-Console $Line $Color
}

function Add-Result {
    param(
        [string]$Category,[string]$Item,[string]$Source,[string]$Destination,
        [ValidateSet('OK','WARNING','ERROR','SKIPPED','INFO')]
        [string]$Status,[int]$ExitCode = 0,[string]$Message = '',
        [int64]$SourceSize = 0,[int64]$DestinationSize = 0,
        [int64]$SourceFiles = 0,[int64]$DestinationFiles = 0
    )
    $Results.Add([PSCustomObject]@{
        Category=$Category; Item=$Item; Source=$Source; Destination=$Destination
        Status=$Status; ExitCode=$ExitCode; Message=$Message
        SourceSize=$SourceSize; DestinationSize=$DestinationSize
        SourceFiles=$SourceFiles; DestinationFiles=$DestinationFiles
    })
}

function Format-Size {
    param([AllowNull()][double]$Bytes)
    if ($null -eq $Bytes) { return 'N/D' }
    if ($Bytes -ge 1TB) { return '{0:N2} TB' -f ($Bytes/1TB) }
    if ($Bytes -ge 1GB) { return '{0:N2} GB' -f ($Bytes/1GB) }
    if ($Bytes -ge 1MB) { return '{0:N2} MB' -f ($Bytes/1MB) }
    if ($Bytes -ge 1KB) { return '{0:N2} KB' -f ($Bytes/1KB) }
    return '{0:N0} bytes' -f $Bytes
}

function Get-ProfilePath {
    param([string]$Name)

    if ($Name -ieq $env:USERNAME -and (Test-Path -LiteralPath $env:USERPROFILE)) {
        return (Resolve-Path -LiteralPath $env:USERPROFILE).Path
    }

    $Default = Join-Path 'C:\Users' $Name
    if (Test-Path -LiteralPath $Default) {
        return (Resolve-Path -LiteralPath $Default).Path
    }

    $Key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    try {
        foreach ($Profile in (Get-ItemProperty "$Key\*" -ErrorAction Stop)) {
            if ([string]::IsNullOrWhiteSpace($Profile.ProfileImagePath)) { continue }
            $Path = [Environment]::ExpandEnvironmentVariables($Profile.ProfileImagePath)
            if ((Split-Path -Leaf $Path) -ieq $Name -and (Test-Path -LiteralPath $Path)) {
                return (Resolve-Path -LiteralPath $Path).Path
            }
        }
    } catch {
        Write-Log "Falha ao consultar ProfileList: $($_.Exception.Message)" Yellow
    }
    return $null
}

function Get-FolderStats {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return [PSCustomObject]@{
            Files = [int64]0
            Bytes = [int64]0
        }
    }

    $Files = @(Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)

    if ($Files.Count -eq 0) {
        return [PSCustomObject]@{
            Files = [int64]0
            Bytes = [int64]0
        }
    }

    $Measure = $Files | Measure-Object -Property Length -Sum
    $Sum = if ($null -eq $Measure -or $null -eq $Measure.Sum) { 0 } else { $Measure.Sum }

    [PSCustomObject]@{
        Files = [int64]$Files.Count
        Bytes = [int64]$Sum
    }
}

function Get-FreeSpaceBytes {
    param([string]$Path)
    try {
        $Resolved = Resolve-Path -LiteralPath $Path
        $Root = [IO.Path]::GetPathRoot($Resolved.Path)

        if ($Root -match '^[A-Za-z]:\\$') {
            return [int64](Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$($Root.Substring(0,2))'").FreeSpace
        }

        $Drive = Get-PSDrive | Where-Object { $_.Root -and $Resolved.Path.StartsWith($_.Root,[StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1
        if ($Drive) { return [int64]$Drive.Free }
    } catch {
        Write-Log "Não foi possível determinar espaço livre: $($_.Exception.Message)" Yellow
    }
    return $null
}

function Invoke-Robocopy {
    param([string]$Source,[string]$Destination,[string]$ItemName,[string]$Category='UserData')

    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Log "[PULADO] $ItemName - origem inexistente." DarkGray
        Add-Result $Category $ItemName $Source $Destination 'SKIPPED' 0 'Origem inexistente.'
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Source,"Copiar para $Destination")) {
        Add-Result $Category $ItemName $Source $Destination 'SKIPPED' 0 'WhatIf.'
        return
    }

    try {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        $SrcStats = Get-FolderStats $Source

        $Args = @(
            "`"$Source`"","`"$Destination`"",
            '/E',"/MT:$Threads", "/R:$RetryCount", "/W:$WaitSeconds",
            '/Z','/FFT','/COPY:DAT','/DCOPY:DAT','/XJ','/XJD','/XJF',
            '/NP',"/LOG+:`"$RobocopyLog`""
        )

        Write-Log "Copiando $ItemName..." White
        $P = Start-Process robocopy.exe -ArgumentList ($Args -join ' ') -Wait -PassThru -NoNewWindow
        $Code = $P.ExitCode

        $DstStats = Get-FolderStats $Destination

        if ($Code -ge 8) {
            $Status='ERROR'
            $Message="Robocopy código $Code."
            Write-Log "[ERRO] $ItemName - $Message" Red
        } elseif ($Code -ge 4) {
            $Status='WARNING'
            $Message="Robocopy código $Code; revisar log."
            Write-Log "[WARNING] $ItemName - $Message" Yellow
        } else {
            $Status='OK'
            $Message="Cópia concluída."
            Write-Log "[OK] $ItemName - código $Code" Green
        }

        Add-Result $Category $ItemName $Source $Destination $Status $Code $Message `
            $SrcStats.Bytes $DstStats.Bytes $SrcStats.Files $DstStats.Files
    } catch {
        Write-Log "[ERRO] $ItemName - $($_.Exception.Message)" Red
        Add-Result $Category $ItemName $Source $Destination 'ERROR' 0 $_.Exception.Message
    }
}

function Copy-FileSafe {
    param([string]$Source,[string]$Destination,[string]$ItemName,[string]$Category='Config')

    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) {
        Add-Result $Category $ItemName $Source $Destination 'SKIPPED' 0 'Arquivo inexistente.'
        return
    }

    if (-not $PSCmdlet.ShouldProcess($Source,"Copiar para $Destination")) { return }

    try {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
        Add-Result $Category $ItemName $Source $Destination 'OK' 0 'Arquivo copiado.'
        Write-Log "[OK] $ItemName" Green
    } catch {
        Add-Result $Category $ItemName $Source $Destination 'ERROR' 0 $_.Exception.Message
        Write-Log "[ERRO] $ItemName - $($_.Exception.Message)" Red
    }
}

function Get-BrowserProfiles {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    @(Get-ChildItem -LiteralPath $Path -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object {$_.Name -eq 'Default' -or $_.Name -like 'Profile *'})
}

function Get-MappedDrives {
    $Items = @()
    try {
        Get-CimInstance Win32_LogicalDisk -Filter "DriveType=4" -ErrorAction SilentlyContinue |
            ForEach-Object {
                $Items += [PSCustomObject]@{
                    Drive=$_.DeviceID; Path=$_.ProviderName; Description=$_.VolumeName
                }
            }
    } catch {}
    return $Items
}

function Get-PrintersInventory {
    $Items=@()
    try {
        Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | ForEach-Object {
            $Items += [PSCustomObject]@{
                Name=$_.Name; Driver=$_.DriverName; Port=$_.PortName
                Shared=$_.Shared; Default=$_.Default
            }
        }
    } catch {}
    return $Items
}

function Get-OneDriveInfo {
    $Items=@()
    try {
        Get-ChildItem Env: | Where-Object {$_.Name -like 'OneDrive*'} | ForEach-Object {
            if ($_.Value -and (Test-Path -LiteralPath $_.Value)) {
                $Items += [PSCustomObject]@{ Name=$_.Name; Path=$_.Value }
            }
        }
    } catch {}
    return $Items
}

function Get-WindowsInfo {
    try {
        $OS=Get-CimInstance Win32_OperatingSystem
        return [PSCustomObject]@{
            Caption=$OS.Caption; Version=$OS.Version; Build=$OS.BuildNumber
            Architecture=$OS.OSArchitecture; LastBoot=$OS.LastBootUpTime
        }
    } catch { return [PSCustomObject]@{} }
}

function Export-Wifi {
    if (-not $IncludeWifi) {
        Write-Log '[PULADO] Wi-Fi não solicitado.' DarkGray
        return
    }

    $Folder=Join-Path $TargetBackupDir 'WiFi_Profiles'
    if (-not $PSCmdlet.ShouldProcess($Folder,'Exportar perfis Wi-Fi')) { return }

    try {
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
        & netsh.exe wlan export profile folder="$Folder" key=clear 2>&1 | Out-Null
        $Files=@(Get-ChildItem -LiteralPath $Folder -Filter '*.xml' -File -ErrorAction SilentlyContinue)

        if ($Files.Count -gt 0) {
            Add-Result 'WiFi' 'Perfis Wi-Fi' 'netsh wlan' $Folder 'WARNING' 0 `
                "$($Files.Count) perfil(is) exportado(s). XMLs podem conter chaves."
            Write-Log "[WARNING] $($Files.Count) perfil(is) Wi-Fi exportado(s)." Yellow
        } else {
            Add-Result 'WiFi' 'Perfis Wi-Fi' 'netsh wlan' $Folder 'WARNING' 0 'Nenhum perfil exportado.'
        }
    } catch {
        Add-Result 'WiFi' 'Perfis Wi-Fi' 'netsh wlan' $Folder 'ERROR' 0 $_.Exception.Message
        Write-Log "[ERRO] Wi-Fi: $($_.Exception.Message)" Red
    }
}

function Export-CertificatesInventory {
    if (-not $IncludeCertificates) { return }

    $Folder=Join-Path $TargetBackupDir 'Certificates'
    if (-not $PSCmdlet.ShouldProcess($Folder,'Inventariar certificados')) { return }

    try {
        New-Item -ItemType Directory -Path $Folder -Force | Out-Null
        $Certs=Get-ChildItem Cert:\CurrentUser\My -ErrorAction SilentlyContinue |
            Select-Object Subject,Issuer,Thumbprint,NotBefore,NotAfter,HasPrivateKey

        $Certs | ConvertTo-Json -Depth 5 | Set-Content (Join-Path $Folder 'user_certificates.json') -Encoding UTF8

        Add-Result 'Certificates' 'Certificados do usuário' 'Cert:\CurrentUser\My' $Folder 'OK' 0 `
            "$(@($Certs).Count) certificado(s) inventariado(s)."
    } catch {
        Add-Result 'Certificates' 'Certificados do usuário' 'Cert:\CurrentUser\My' $Folder 'ERROR' 0 $_.Exception.Message
    }
}

function Find-LargeFiles {
    if (-not $IncludeLargeFilesReport) { return @() }

    $Threshold=$LargeFileThresholdMB * 1MB
    try {
        @(Get-ChildItem -LiteralPath $UserProfilePath -Recurse -File -Force -ErrorAction SilentlyContinue |
            Where-Object {$_.Length -ge $Threshold} |
            Sort-Object Length -Descending |
            Select-Object -First 100 FullName,Length,LastWriteTime)
    } catch { @() }
}

function Get-CriticalFiles {
    $List=@()
    $List += @(Get-ChildItem -LiteralPath (Join-Path $UserProfilePath 'AppData\Local\Google\Chrome\User Data') -Filter Bookmarks -File -Recurse -ErrorAction SilentlyContinue)
    $List += @(Get-ChildItem -LiteralPath (Join-Path $UserProfilePath 'AppData\Local\Microsoft\Edge\User Data') -Filter Bookmarks -File -Recurse -ErrorAction SilentlyContinue)
    $List += @(Get-ChildItem -LiteralPath (Join-Path $UserProfilePath 'AppData\Roaming\Microsoft\Signatures') -File -Recurse -ErrorAction SilentlyContinue)
    return $List
}

function New-HtmlReport {
    param([object]$Manifest,[string]$Path)

    $Rows = foreach ($R in $Results) {
        $Class = switch ($R.Status) {
            'OK' {'ok'} 'WARNING' {'warning'} 'ERROR' {'error'} default {'skip'}
        }
        "<tr class='$Class'><td>$($R.Category)</td><td>$($R.Item)</td><td>$($R.Status)</td><td>$($R.SourceFiles)</td><td>$($R.DestinationFiles)</td><td>$($R.Message)</td></tr>"
    }

    $Html=@"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="utf-8">
<title>Relatório de Migração - $ComputerName</title>
<style>
body{font-family:Segoe UI,Arial;margin:30px;background:#f5f6f8;color:#222}
.card{background:white;padding:20px;margin-bottom:20px;border-radius:8px;box-shadow:0 1px 4px #ccc}
h1{margin-top:0}table{width:100%;border-collapse:collapse;background:white}
th,td{padding:8px;border-bottom:1px solid #ddd;text-align:left;font-size:13px}
th{background:#eee}.ok{background:#e9f7ed}.warning{background:#fff7df}.error{background:#fdeaea}.skip{background:#f3f3f3}
.grid{display:grid;grid-template-columns:repeat(4,1fr);gap:10px}
.metric{padding:15px;background:#f1f3f5;border-radius:6px}.metric b{font-size:22px}
</style>
</head>
<body>
<div class="card">
<h1>Relatório de Backup / Migração</h1>
<p><b>Computador:</b> $ComputerName</p>
<p><b>Usuário:</b> $UserName</p>
<p><b>Origem:</b> $UserProfilePath</p>
<p><b>Destino:</b> $TargetBackupDir</p>
<p><b>Data:</b> $StartTime</p>
</div>
<div class="card">
<div class="grid">
<div class="metric"><b>$($Manifest.Summary.Status)</b><br>Status</div>
<div class="metric"><b>$($Manifest.Summary.OK)</b><br>OK</div>
<div class="metric"><b>$($Manifest.Summary.Warning)</b><br>Avisos</div>
<div class="metric"><b>$($Manifest.Summary.Error)</b><br>Erros</div>
</div>
<p><b>Tamanho:</b> $($Manifest.TotalSizeFormatted) &nbsp; <b>Duração:</b> $($Manifest.Duration)</p>
</div>
<div class="card">
<h2>Itens</h2>
<table>
<tr><th>Categoria</th><th>Item</th><th>Status</th><th>Origem</th><th>Destino</th><th>Mensagem</th></tr>
$($Rows -join "`n")
</table>
</div>
</body>
</html>
"@

    $Html | Set-Content -LiteralPath $Path -Encoding UTF8
}

# ============================================================================
# INÍCIO
# ============================================================================

Write-Console ''
Write-Console '============================================================' Cyan
Write-Console '        BACKUP / MIGRAÇÃO DE PERFIL - V2.0' Cyan
Write-Console '============================================================' Cyan
Write-Console ''

try {
    $UserProfilePath=Get-ProfilePath $UserName
    if (-not $UserProfilePath) { throw "Perfil '$UserName' não encontrado." }

    $Inventory.ComputerName=$ComputerName
    $Inventory.UserName=$UserName
    $Inventory.ProfilePath=$UserProfilePath
    $Inventory.Windows=Get-WindowsInfo
    $Inventory.MappedDrives=Get-MappedDrives
    $Inventory.Printers=Get-PrintersInventory
    $Inventory.OneDrive=Get-OneDriveInfo

    Write-Log "Perfil encontrado: $UserProfilePath" Green

    $FoldersToAnalyze=@(
        'Desktop','Documents','Downloads','Pictures','Videos','Music',
        'Favorites','OneDrive'
    )

    $Inventory.FolderStats=[ordered]@{}
    foreach ($Folder in $FoldersToAnalyze) {
        $Path=Join-Path $UserProfilePath $Folder
        if (Test-Path -LiteralPath $Path) {
            $Inventory.FolderStats[$Folder]=Get-FolderStats $Path
        }
    }

    $LargeFiles=Find-LargeFiles
    $Inventory.LargeFiles=$LargeFiles

    if ($Mode -eq 'Inventory') {
        $InventoryPath=Join-Path $DestinationPath "Inventory_${UserName}_${ComputerName}_$Timestamp.json"
        if ($PSCmdlet.ShouldProcess($InventoryPath,'Salvar inventário')) {
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
            $Inventory | ConvertTo-Json -Depth 10 | Set-Content $InventoryPath -Encoding UTF8
        }

        Write-Console ''
        Write-Console 'INVENTÁRIO CONCLUÍDO' Green
        Write-Console "Arquivo: $InventoryPath" Cyan
        exit 0
    }

    if (-not (Test-Path -LiteralPath $DestinationPath)) {
        if ($PSCmdlet.ShouldProcess($DestinationPath,'Criar destino')) {
            New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
        }
    }

    $TargetBackupDir=Join-Path $DestinationPath "Backup_${UserName}_${ComputerName}_$Timestamp"

    if ($PSCmdlet.ShouldProcess($TargetBackupDir,'Criar pasta do backup')) {
        New-Item -ItemType Directory -Path $TargetBackupDir -Force | Out-Null
    }

    $LogFile=Join-Path $TargetBackupDir "backup_$Timestamp.log"
    $RobocopyLog=Join-Path $TargetBackupDir "robocopy_$Timestamp.log"
    New-Item -ItemType File -Path $LogFile -Force | Out-Null
    New-Item -ItemType File -Path $RobocopyLog -Force | Out-Null

    Write-Log "Backup V$ScriptVersion iniciado." Cyan
    Write-Log "Computador: $ComputerName | Usuário: $UserName"
    Write-Log "Origem: $UserProfilePath"
    Write-Log "Destino: $TargetBackupDir"

    $Free=Get-FreeSpaceBytes $DestinationPath
    if ($Free -ne $null) { Write-Log "Espaço livre no destino: $(Format-Size $Free)" }

    # Dados pessoais
    $Folders=@(
        @{N='Desktop';S='Desktop';E=$true},
        @{N='Documents';S='Documents';E=$true},
        @{N='Favorites';S='Favorites';E=$true}
    )

    if ($IncludeDownloads) { $Folders+=@{N='Downloads';S='Downloads';E=$true} }
    if ($IncludeMedia) {
        $Folders+=@{N='Pictures';S='Pictures';E=$true}
        $Folders+=@{N='Videos';S='Videos';E=$true}
        $Folders+=@{N='Music';S='Music';E=$true}
    }

    foreach ($F in $Folders) {
        Invoke-Robocopy `
            (Join-Path $UserProfilePath $F.S) `
            (Join-Path $TargetBackupDir $F.S) `
            $F.N 'UserData'
    }

    # Outlook - assinaturas
    Invoke-Robocopy `
        (Join-Path $UserProfilePath 'AppData\Roaming\Microsoft\Signatures') `
        (Join-Path $TargetBackupDir 'AppData_Config\Outlook_Signatures') `
        'Outlook - Assinaturas' 'Outlook'

    # Outlook - PST somente
    $PstSource=Join-Path $UserProfilePath 'Documents\Outlook Files'
    Invoke-Robocopy $PstSource (Join-Path $TargetBackupDir 'Outlook\PST') 'Outlook - PST' 'Outlook'

    # Outlook em AppData/Local/Microsoft/Outlook
    $PstLocal=Join-Path $UserProfilePath 'AppData\Local\Microsoft\Outlook'
    if (Test-Path -LiteralPath $PstLocal) {
        Get-ChildItem -LiteralPath $PstLocal -Filter '*.pst' -File -ErrorAction SilentlyContinue |
            ForEach-Object {
                Copy-FileSafe $_.FullName (Join-Path $TargetBackupDir 'Outlook\PST') $_.Name 'Outlook'
            }
    }

    # OST: inventário, não cópia
    $Ost=@(Get-ChildItem -LiteralPath $UserProfilePath -Filter '*.ost' -File -Recurse -ErrorAction SilentlyContinue)
    if ($Ost.Count -gt 0) {
        $Inventory.OstFiles=$Ost | Select-Object FullName,Length,LastWriteTime
        Write-Log "[INFO] $($Ost.Count) OST encontrado(s). Não serão copiados." Yellow
    }

    # Chrome / Edge
    foreach ($Browser in @(
        @{Name='Chrome';Path='AppData\Local\Google\Chrome\User Data'},
        @{Name='Edge';Path='AppData\Local\Microsoft\Edge\User Data'}
    )) {
        $Root=Join-Path $UserProfilePath $Browser.Path
        foreach ($Profile in (Get-BrowserProfiles $Root)) {
            Copy-FileSafe `
                (Join-Path $Profile.FullName 'Bookmarks') `
                (Join-Path $TargetBackupDir "AppData_Config\$($Browser.Name)_Bookmarks\$($Profile.Name)") `
                "$($Browser.Name) - $($Profile.Name) - Bookmarks" `
                $Browser.Name
        }
    }

    # Sticky Notes
    Invoke-Robocopy `
        (Join-Path $UserProfilePath 'AppData\Local\Packages\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe\LocalState') `
        (Join-Path $TargetBackupDir 'AppData_Config\StickyNotes') `
        'Sticky Notes' 'StickyNotes'

    # OneDrive - somente conteúdo local, se existir como pasta real
    foreach ($OD in $Inventory.OneDrive) {
        Invoke-Robocopy $OD.Path `
            (Join-Path $TargetBackupDir "OneDrive\$($OD.Name)") `
            "OneDrive - $($OD.Name)" 'OneDrive'
    }

    Export-Wifi
    Export-CertificatesInventory

    # Inventário adicional
    if ($PSCmdlet.ShouldProcess($TargetBackupDir,'Salvar inventário')) {
        $Inventory | ConvertTo-Json -Depth 12 |
            Set-Content (Join-Path $TargetBackupDir 'inventory.json') -Encoding UTF8
    }

    if ($IncludeLargeFilesReport -and $LargeFiles.Count -gt 0) {
        $LargeFiles | Export-Csv `
            (Join-Path $TargetBackupDir 'large_files.csv') `
            -NoTypeInformation -Encoding UTF8
    }

    # Validação
    $Validation=@()
    if ($Validate) {
        Write-Log 'Iniciando validação pós-backup...' Cyan

        foreach ($R in @($Results | Where-Object {$_.Status -in @('OK','WARNING') -and $_.Source -and $_.Destination})) {
            if ((Test-Path -LiteralPath $R.Source) -and (Test-Path -LiteralPath $R.Destination)) {
                $S=Get-FolderStats $R.Source
                $D=Get-FolderStats $R.Destination
                $Match=($S.Files -eq $D.Files -and $S.Bytes -eq $D.Bytes)

                $Validation += [PSCustomObject]@{
                    Item=$R.Item; SourceFiles=$S.Files; DestinationFiles=$D.Files
                    SourceBytes=$S.Bytes; DestinationBytes=$D.Bytes; Valid=$Match
                }

                if (-not $Match) {
                    Write-Log "[WARNING] Validação diferente: $($R.Item) | Origem $(Format-Size $S.Bytes), destino $(Format-Size $D.Bytes)" Yellow
                    $R.Status='WARNING'
                    $R.Message='Validação: quantidade/tamanho diferente.'
                }
            }
        }

        $Validation | Export-Csv (Join-Path $TargetBackupDir 'validation.csv') -NoTypeInformation -Encoding UTF8
    }

    # Hash dos arquivos críticos
    if ($HashCriticalFiles) {
        $HashRows=@()
        foreach ($File in (Get-CriticalFiles)) {
            try {
                $HashRows += Get-FileHash -LiteralPath $File.FullName -Algorithm SHA256 |
                    Select-Object Path,Algorithm,Hash
            } catch {}
        }

        $HashRows | Export-Csv (Join-Path $TargetBackupDir 'critical_files_sha256.csv') -NoTypeInformation -Encoding UTF8
    }

    $EndTime=Get-Date
    $Duration=$EndTime-$StartTime
    $TotalSize=(Get-FolderStats $TargetBackupDir).Bytes

    $OK=@($Results|Where-Object Status -eq 'OK').Count
    $WARN=@($Results|Where-Object Status -eq 'WARNING').Count
    $ERR=@($Results|Where-Object Status -eq 'ERROR').Count
    $SKIP=@($Results|Where-Object Status -eq 'SKIPPED').Count

    $Overall=if($ERR -gt 0){'ERROR'}elseif($WARN -gt 0){'WARNING'}else{'SUCCESS'}

    $Manifest=[ordered]@{
        ScriptVersion=$ScriptVersion
        ComputerName=$ComputerName
        UserName=$UserName
        Source=$UserProfilePath
        Destination=$TargetBackupDir
        StartTime=$StartTime.ToString('o')
        EndTime=$EndTime.ToString('o')
        Duration=$Duration.ToString()
        TotalSize=$TotalSize
        TotalSizeFormatted=(Format-Size $TotalSize)
        Options=[ordered]@{
            IncludeDownloads=[bool]$IncludeDownloads
            IncludeMedia=[bool]$IncludeMedia
            IncludeWifi=[bool]$IncludeWifi
            IncludeCertificates=[bool]$IncludeCertificates
            Validate=[bool]$Validate
            HashCriticalFiles=[bool]$HashCriticalFiles
        }
        Summary=[ordered]@{
            Status=$Overall;OK=$OK;Warning=$WARN;Error=$ERR;Skipped=$SKIP
        }
        Inventory=$Inventory
        Items=$Results
    }

    $ManifestPath=Join-Path $TargetBackupDir 'backup_manifest.json'
    $Manifest | ConvertTo-Json -Depth 15 | Set-Content $ManifestPath -Encoding UTF8

    New-HtmlReport $Manifest (Join-Path $TargetBackupDir 'Backup_Report.html')

    Write-Console ''
    Write-Console '============================================================' Cyan
    Write-Console '                 BACKUP FINALIZADO' Cyan
    Write-Console '============================================================' Cyan
    Write-Console " Status  : $Overall" $(if($Overall -eq 'SUCCESS'){'Green'}elseif($Overall -eq 'WARNING'){'Yellow'}else{'Red'})
    Write-Console " OK      : $OK" Green
    Write-Console " Avisos  : $WARN" Yellow
    Write-Console " Erros   : $ERR" Red
    Write-Console " Pulados : $SKIP" DarkGray
    Write-Console " Tamanho : $(Format-Size $TotalSize)"
    Write-Console " Tempo   : $($Duration.ToString('hh\:mm\:ss'))"
    Write-Console " Backup  : $TargetBackupDir" Cyan
    Write-Console " Relatório: $(Join-Path $TargetBackupDir 'Backup_Report.html')" Cyan
    Write-Console '============================================================' Cyan

    if($ERR -gt 0){exit 2}
    if($WARN -gt 0){exit 1}
    exit 0
}
catch {
    Write-Console "[FATAL] $($_.Exception.Message)" Red
    if($LogFile){Write-Log "[FATAL] $($_.Exception.Message)" Red}
    exit 3
}
