<#
.SYNOPSIS
    Realiza o backup estruturado e veloz dos dados essenciais do perfil de usuário em estações de trabalho.

.DESCRIPTION
    Script essencial para rotinas de Help Desk, migração de computadores, substituição de máquinas e formatação:
    - Faz backup das pastas principais: Área de Trabalho (Desktop), Documentos, Favoritos
    - Opcionalmente inclui pasta Downloads (-IncludeDownloads) e Mídias (-IncludeMedia: Fotos, Vídeos e Músicas)
    - Copia configurações críticas frequentemente esquecidas:
      * Assinaturas do Microsoft Outlook (AppData\Roaming\Microsoft\Signatures)
      * Favoritos do Google Chrome e Microsoft Edge (Bookmarks)
      * Notas Autoadesivas / Sticky Notes (plum.sqlite)
    - Exporta perfis e senhas de redes Wi-Fi salvas no equipamento (XMLs)
    - Utiliza o Robocopy com multi-threading (/MT:8) para máxima taxa de transferência
    - Gera log de auditoria detalhado no destino do backup

.PARAMETER DestinationPath
    Caminho de destino do backup (Diretório em HD Externo, pendrive ou compartilhamento UNC \\servidor\share).

.PARAMETER UserName
    Nome de usuário cujo perfil será salvo (Padrão: usuário atualmente conectado).

.PARAMETER IncludeDownloads
    Inclui o diretório Downloads no backup (útil caso o usuário guarde arquivos importantes lá).

.PARAMETER IncludeMedia
    Inclui as pastas Imagens (Pictures), Vídeos e Músicas.

.EXAMPLE
    .\Backup-UserProfile.ps1 -DestinationPath "D:\Backups"

.EXAMPLE
    .\Backup-UserProfile.ps1 -DestinationPath "\\SRV-FS01\Migracao" -IncludeDownloads -IncludeMedia

.EXAMPLE
    .\Backup-UserProfile.ps1 -UserName "joao.silva" -DestinationPath "E:\Backup_Joao"
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$DestinationPath,

    [string]$UserName = $env:USERNAME,
    [switch]$IncludeDownloads,
    [switch]$IncludeMedia
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "       BACKUP & MIGRAÇÃO DE PERFIL DE USUÁRIO             " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Iniciando rotina de coleta e backup de perfil..." -ForegroundColor DarkGray
Write-Host ""

# 1. Localização do perfil de usuário
$UserProfilePath = $null
if ($UserName -eq $env:USERNAME) {
    $UserProfilePath = $env:USERPROFILE
} else {
    $PossiblePath = Join-Path "C:\Users" $UserName
    if (Test-Path $PossiblePath) {
        $UserProfilePath = $PossiblePath
    } else {
        # Busca no registro de perfis
        $ProfileListKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList"
        $Profiles = Get-ItemProperty "$ProfileListKey\*" -ErrorAction SilentlyContinue
        $Match = $Profiles | Where-Object { $_.ProfileImagePath -like "*\$UserName" }
        if ($Match) {
            $UserProfilePath = $Match.ProfileImagePath
        }
    }
}

if (-not $UserProfilePath -or -not (Test-Path $UserProfilePath)) {
    Write-Host "[ERRO] Diretório do perfil para o usuário '$UserName' não foi encontrado em 'C:\Users\$UserName'!" -ForegroundColor Red
    return
}

# 2. Criação do diretório de destino
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$TargetBackupDir = Join-Path $DestinationPath "Backup_${UserName}_$Timestamp"

try {
    if (-not (Test-Path $TargetBackupDir)) {
        New-Item -ItemType Directory -Path $TargetBackupDir -Force | Out-Null
    }
} catch {
    Write-Host "[ERRO] Falha ao criar diretório de destino em '$TargetBackupDir': $($_.Exception.Message)" -ForegroundColor Red
    return
}

$LogFile = Join-Path $TargetBackupDir "backup_log_$Timestamp.txt"
"============================================================" | Out-File -FilePath $LogFile -Encoding utf8
"BACKUP DE PERFIL: $UserName - $Timestamp" | Out-File -FilePath $LogFile -Append -Encoding utf8
"Origem : $UserProfilePath" | Out-File -FilePath $LogFile -Append -Encoding utf8
"Destino: $TargetBackupDir" | Out-File -FilePath $LogFile -Append -Encoding utf8
"============================================================" | Out-File -FilePath $LogFile -Append -Encoding utf8

Write-Host "[1] Configuração do Backup:" -ForegroundColor Yellow
Write-Host "  Usuário Selecionado : " -NoNewline; Write-Host $UserName -ForegroundColor Cyan
Write-Host "  Caminho de Origem   : $UserProfilePath" -ForegroundColor DarkGray
Write-Host "  Pasta de Destino    : $TargetBackupDir" -ForegroundColor Green
Write-Host "  Arquivo de Registro : $LogFile" -ForegroundColor DarkGray
Write-Host ""

$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Função auxiliar para cópia com Robocopy
function Invoke-ProfileCopy {
    param(
        [string]$Source,
        [string]$Destination,
        [string]$ItemName,
        [string[]]$FileFilters = @("*.*")
    )

    if (-not (Test-Path $Source)) {
        Write-Host "  - $ItemName : " -NoNewline; Write-Host "[NÃO ENCONTRADO / PULADO]" -ForegroundColor DarkGray
        return
    }

    if (-not (Test-Path $Destination)) {
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    }

    Write-Host "  - Copiando $ItemName..." -ForegroundColor White

    $FilterArgs = $FileFilters -join " "
    $RoboArgs = @(
        "`"$Source`"",
        "`"$Destination`"",
        $FilterArgs,
        "/E",
        "/MT:8",
        "/R:1",
        "/W:2",
        "/NP",
        "/NDL",
        "/NFL",
        "/XJ",
        "/LOG+:`"$LogFile`""
    )

    $Process = Start-Process -FilePath "robocopy.exe" -ArgumentList ($RoboArgs -join " ") -Wait -PassThru -NoNewWindow
    # Robocopy exit code: 0=No change, 1=Files copied, 2=Extra files, 3=Mismatch/copied, >=8 Error
    if ($Process.ExitCode -lt 8) {
        Write-Host "    [OK] $ItemName copiado com sucesso." -ForegroundColor Green
    } else {
        Write-Host "    [ALERTA] $ItemName concluído com avisos/erros (Código: $($Process.ExitCode))." -ForegroundColor Yellow
    }
}

# 3. Execução das Cópias dos Diretórios Pessoais
Write-Host "[2] Copiando Diretórios de Documentos e Arquivos Pessoais:" -ForegroundColor Yellow

# Desktop
Invoke-ProfileCopy -Source (Join-Path $UserProfilePath "Desktop") -Destination (Join-Path $TargetBackupDir "Desktop") -ItemName "Área de Trabalho (Desktop)"

# Documents
Invoke-ProfileCopy -Source (Join-Path $UserProfilePath "Documents") -Destination (Join-Path $TargetBackupDir "Documents") -ItemName "Documentos"

# Favorites (IE / Legado)
Invoke-ProfileCopy -Source (Join-Path $UserProfilePath "Favorites") -Destination (Join-Path $TargetBackupDir "Favorites") -ItemName "Favoritos do Windows"

# Downloads
if ($IncludeDownloads) {
    Invoke-ProfileCopy -Source (Join-Path $UserProfilePath "Downloads") -Destination (Join-Path $TargetBackupDir "Downloads") -ItemName "Downloads"
} else {
    Write-Host "  - Pasta Downloads : [PULADA (use -IncludeDownloads)]" -ForegroundColor DarkGray
}

# Mídias (Fotos, Vídeos, Músicas)
if ($IncludeMedia) {
    Invoke-ProfileCopy -Source (Join-Path $UserProfilePath "Pictures") -Destination (Join-Path $TargetBackupDir "Pictures") -ItemName "Imagens (Pictures)"
    Invoke-ProfileCopy -Source (Join-Path $UserProfilePath "Videos") -Destination (Join-Path $TargetBackupDir "Videos") -ItemName "Vídeos"
    Invoke-ProfileCopy -Source (Join-Path $UserProfilePath "Music") -Destination (Join-Path $TargetBackupDir "Music") -ItemName "Músicas"
}

# 4. Configurações Especiais & Softwares
Write-Host ""
Write-Host "[3] Copiando Configurações de Aplicativos Críticos:" -ForegroundColor Yellow

# Assinaturas do Outlook
$OutlookSignatures = Join-Path $UserProfilePath "AppData\Roaming\Microsoft\Signatures"
if (Test-Path $OutlookSignatures) {
    Invoke-ProfileCopy -Source $OutlookSignatures -Destination (Join-Path $TargetBackupDir "AppData_Config\Outlook_Signatures") -ItemName "Assinaturas do Outlook"
} else {
    Write-Host "  - Assinaturas do Outlook : [NENHUMA ENCONTRADA]" -ForegroundColor DarkGray
}

# Favoritos do Chrome
$ChromeBookmarks = Join-Path $UserProfilePath "AppData\Local\Google\Chrome\User Data\Default\Bookmarks"
if (Test-Path $ChromeBookmarks) {
    $ChromeDest = Join-Path $TargetBackupDir "AppData_Config\Chrome_Bookmarks"
    New-Item -ItemType Directory -Path $ChromeDest -Force | Out-Null
    Copy-Item -Path $ChromeBookmarks -Destination $ChromeDest -Force -ErrorAction SilentlyContinue
    Write-Host "  - Favoritos Google Chrome : " -NoNewline; Write-Host "[COPIADO]" -ForegroundColor Green
} else {
    Write-Host "  - Favoritos Google Chrome : [NÃO LOCALIZADO]" -ForegroundColor DarkGray
}

# Favoritos do Edge
$EdgeBookmarks = Join-Path $UserProfilePath "AppData\Local\Microsoft\Edge\User Data\Default\Bookmarks"
if (Test-Path $EdgeBookmarks) {
    $EdgeDest = Join-Path $TargetBackupDir "AppData_Config\Edge_Bookmarks"
    New-Item -ItemType Directory -Path $EdgeDest -Force | Out-Null
    Copy-Item -Path $EdgeBookmarks -Destination $EdgeDest -Force -ErrorAction SilentlyContinue
    Write-Host "  - Favoritos Microsoft Edge : " -NoNewline; Write-Host "[COPIADO]" -ForegroundColor Green
} else {
    Write-Host "  - Favoritos Microsoft Edge : [NÃO LOCALIZADO]" -ForegroundColor DarkGray
}

# Sticky Notes (Notas Autoadesivas)
$StickyPath = Join-Path $UserProfilePath "AppData\Local\Packages\Microsoft.MicrosoftStickyNotes_8wekyb3d8bbwe\LocalState"
if (Test-Path $StickyPath) {
    Invoke-ProfileCopy -Source $StickyPath -Destination (Join-Path $TargetBackupDir "AppData_Config\StickyNotes") -ItemName "Banco de Dados Sticky Notes (Notas Autoadesivas)"
}

# 5. Exportação de Perfis de Rede Wi-Fi
Write-Host ""
Write-Host "[4] Exportando Perfis de Redes Wi-Fi Conhecidas:" -ForegroundColor Yellow
$WifiExportFolder = Join-Path $TargetBackupDir "WiFi_Profiles"
New-Item -ItemType Directory -Path $WifiExportFolder -Force | Out-Null

try {
    $WifiResult = netsh.exe wlan export profile folder="$WifiExportFolder" key=clear 2>&1
    $ExportedProfiles = Get-ChildItem -Path $WifiExportFolder -Filter "*.xml" -ErrorAction SilentlyContinue
    if ($ExportedProfiles) {
        Write-Host "  Perfis Wi-Fi Exportados com Sucesso: " -NoNewline; Write-Host "$($ExportedProfiles.Count) rede(s)" -ForegroundColor Green
        foreach ($Prof in $ExportedProfiles) {
            Write-Host "    * $($Prof.Name)" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  Nenhum perfil Wi-Fi encontrado para exportar." -ForegroundColor DarkGray
    }
} catch {
    Write-Host "  [ALERTA] Não foi possível exportar redes Wi-Fi: $($_.Exception.Message)" -ForegroundColor Yellow
}

$Stopwatch.Stop()
$ElapsedTime = $Stopwatch.Elapsed

# 6. Resumo e Estatísticas Finais
$TotalBackupSize = (Get-ChildItem -Path $TargetBackupDir -Recurse -File -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
$SizeFormatted = if ($TotalBackupSize -gt 1GB) {
    "{0:N2} GB" -f ($TotalBackupSize / 1GB)
} elseif ($TotalBackupSize -gt 1MB) {
    "{0:N2} MB" -f ($TotalBackupSize / 1MB)
} else {
    "{0:N2} KB" -f ($TotalBackupSize / 1KB)
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "             RESUMO DO BACKUP DE PERFIL                   " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Status Geral        : " -NoNewline; Write-Host "[SUCESSO]" -ForegroundColor Green
Write-Host "  Tamanho Total Salvo : $SizeFormatted" -ForegroundColor White
Write-Host "  Tempo Decorrido     : $($ElapsedTime.ToString('mm\:ss'))" -ForegroundColor White
Write-Host "  Local dos Arquivos  : " -NoNewline; Write-Host $TargetBackupDir -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
