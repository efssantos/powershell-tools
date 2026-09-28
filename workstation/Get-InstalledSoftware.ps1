<#
.SYNOPSIS
    Inventaria softwares e aplicações instaladas localmente ou em computadores/servidores remotos.

.DESCRIPTION
    Coleta dados detalhados de inventário de softwares instalados:
    - Chaves de registro de 64-bit (HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall)
    - Chaves de registro de 32-bit (HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall)
    - Chaves de registro por usuário (HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall)
    - Opcionalmente lista pacotes UWP / AppX modernos (-IncludeAppx)
    - Suporte a filtro por nome com curingas (-Name "*Chrome*")
    - Suporte a execução remota em outros computadores/servidores (-ComputerName)
    - Exportação para CSV (-ExportCsv) ou relatório HTML (-ExportHtml)
    - Retorna objetos estruturados no pipeline do PowerShell.

.PARAMETER ComputerName
    Nome ou endereço IP dos computadores a serem consultados (Padrão: computador local).

.PARAMETER Name
    Filtro de busca por nome ou editor do software (ex: "*Chrome*", "*Python*", "*Office*").

.PARAMETER IncludeAppx
    Inclui aplicativos do Windows Store / UWP instalados no relatório.

.PARAMETER ExportCsv
    Caminho do arquivo CSV de saída para exportação dos dados.

.PARAMETER ExportHtml
    Caminho do arquivo HTML de saída para gerar um dashboard visual.

.EXAMPLE
    .\Get-InstalledSoftware.ps1

.EXAMPLE
    .\Get-InstalledSoftware.ps1 -Name "*Adobe*"

.EXAMPLE
    .\Get-InstalledSoftware.ps1 -ComputerName "SRV-FILE-01", "PC-FINANCEIRO-05" -ExportCsv "C:\Temp\softwares.csv"

.EXAMPLE
    .\Get-InstalledSoftware.ps1 -ExportHtml "C:\Temp\Inventario_Softwares.html"
#>

[CmdletBinding()]
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [string]$Name,
    [switch]$IncludeAppx,
    [string]$ExportCsv,
    [string]$ExportHtml
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "       INVENTÁRIO DE SOFTWARES INSTALADOS                 " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Consultando base de aplicativos instalados..." -ForegroundColor DarkGray
Write-Host ""

$AllResults = [System.Collections.Generic.List[PSCustomObject]]::new()

function Get-LocalSoftwareList {
    param([string]$TargetHost)

    $SoftwareList = [System.Collections.Generic.List[PSCustomObject]]::new()

    $RegistryPaths = @(
        @{ Hive = "LocalMachine"; Path = "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"; Arch = "64-bit" },
        @{ Hive = "LocalMachine"; Path = "SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"; Arch = "32-bit" }
    )

    if ($TargetHost -eq $env:COMPUTERNAME -or $TargetHost -eq "localhost" -or $TargetHost -eq ".") {
        # Adiciona hive do usuário atual para execução local
        $RegistryPaths += @{ Hive = "CurrentUser"; Path = "Software\Microsoft\Windows\CurrentVersion\Uninstall"; Arch = "User" }

        foreach ($RegConfig in $RegistryPaths) {
            $RootKey = if ($RegConfig.Hive -eq "LocalMachine") { "HKLM:\" } else { "HKCU:\" }
            $FullRegPath = Join-Path $RootKey $RegConfig.Path

            if (Test-Path $FullRegPath) {
                $SubKeys = Get-ChildItem -Path $FullRegPath -ErrorAction SilentlyContinue
                foreach ($SubKey in $SubKeys) {
                    $Properties = Get-ItemProperty -Path $SubKey.PSPath -ErrorAction SilentlyContinue
                    $DisplayName = $Properties.DisplayName
                    
                    # Ignora itens sem nome ou componentes de sistema internos ocultos
                    if ([string]::IsNullOrWhiteSpace($DisplayName) -or $Properties.SystemComponent -eq 1 -or $Properties.ParentKeyName) {
                        continue
                    }

                    $InstallDate = if ($Properties.InstallDate) {
                        $RawDate = [string]$Properties.InstallDate
                        if ($RawDate.Length -eq 8) {
                            "$($RawDate.Substring(0,4))-$($RawDate.Substring(4,2))-$($RawDate.Substring(6,2))"
                        } else {
                            $RawDate
                        }
                    } else { "Desconhecida" }

                    $Item = [PSCustomObject]@{
                        ComputerName    = $TargetHost
                        DisplayName     = $DisplayName.Trim()
                        DisplayVersion  = if ($Properties.DisplayVersion) { [string]$Properties.DisplayVersion } else { "N/A" }
                        Publisher       = if ($Properties.Publisher) { [string]$Properties.Publisher.Trim() } else { "N/A" }
                        InstallDate     = $InstallDate
                        Architecture    = $RegConfig.Arch
                        InstallLocation = if ($Properties.InstallLocation) { [string]$Properties.InstallLocation } else { "N/A" }
                        UninstallString = if ($Properties.UninstallString) { [string]$Properties.UninstallString } else { "N/A" }
                    }
                    $SoftwareList.Add($Item)
                }
            }
        }

        # Pacotes UWP / Appx se solicitado
        if ($IncludeAppx) {
            $AppxPackages = Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue
            foreach ($Pkg in $AppxPackages) {
                if (-not $Pkg.NonRemovable) {
                    $SoftwareList.Add([PSCustomObject]@{
                        ComputerName    = $TargetHost
                        DisplayName     = $Pkg.Name
                        DisplayVersion  = $Pkg.Version
                        Publisher       = $Pkg.PublisherId
                        InstallDate     = "N/A (AppX)"
                        Architecture    = $Pkg.Architecture.ToString()
                        InstallLocation = $Pkg.InstallLocation
                        UninstallString = "Remove-AppxPackage $($Pkg.PackageFullName)"
                    })
                }
            }
        }
    } else {
        # Consulta remota via Invoke-Command / WinRM ou WMI
        try {
            $RemoteBlock = {
                param($IncAppx)
                $RemoteResults = [System.Collections.Generic.List[PSCustomObject]]::new()
                $RegPaths = @(
                    @{ Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"; Arch = "64-bit" },
                    @{ Path = "HKLM:\SOFTWARE\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"; Arch = "32-bit" }
                )

                foreach ($R in $RegPaths) {
                    if (Test-Path $R.Path) {
                        Get-ChildItem -Path $R.Path -ErrorAction SilentlyContinue | ForEach-Object {
                            $P = Get-ItemProperty -Path $_.PSPath -ErrorAction SilentlyContinue
                            if ($P.DisplayName -and -not $P.SystemComponent -and -not $P.ParentKeyName) {
                                $IDate = if ($P.InstallDate) { [string]$P.InstallDate } else { "Desconhecida" }
                                $RemoteResults.Add([PSCustomObject]@{
                                    ComputerName    = $env:COMPUTERNAME
                                    DisplayName     = [string]$P.DisplayName.Trim()
                                    DisplayVersion  = if ($P.DisplayVersion) { [string]$P.DisplayVersion } else { "N/A" }
                                    Publisher       = if ($P.Publisher) { [string]$P.Publisher.Trim() } else { "N/A" }
                                    InstallDate     = $IDate
                                    Architecture    = $R.Arch
                                    InstallLocation = if ($P.InstallLocation) { [string]$P.InstallLocation } else { "N/A" }
                                    UninstallString = if ($P.UninstallString) { [string]$P.UninstallString } else { "N/A" }
                                })
                            }
                        }
                    }
                }

                if ($IncAppx) {
                    Get-AppxPackage -AllUsers -ErrorAction SilentlyContinue | Where-Object { -not $_.NonRemovable } | ForEach-Object {
                        $RemoteResults.Add([PSCustomObject]@{
                            ComputerName    = $env:COMPUTERNAME
                            DisplayName     = $_.Name
                            DisplayVersion  = $_.Version
                            Publisher       = $_.PublisherId
                            InstallDate     = "N/A (AppX)"
                            Architecture    = $_.Architecture.ToString()
                            InstallLocation = $_.InstallLocation
                            UninstallString = "Remove-AppxPackage $($_.PackageFullName)"
                        })
                    }
                }
                return $RemoteResults
            }

            $RemoteData = Invoke-Command -ComputerName $TargetHost -ScriptBlock $RemoteBlock -ArgumentList $IncludeAppx -ErrorAction Stop
            foreach ($R in $RemoteData) {
                $SoftwareList.Add($R)
            }
        } catch {
            Write-Host "  [ERRO] Não foi possível consultar '$TargetHost' remotamente via WinRM: $($_.Exception.Message)" -ForegroundColor Red
        }
    }

    return $SoftwareList
}

# Processamento por computador
foreach ($Computer in $ComputerName) {
    Write-Host "Consultando host: " -NoNewline; Write-Host $Computer -ForegroundColor Cyan
    $HostResults = Get-LocalSoftwareList -TargetHost $Computer

    if ($Name) {
        $HostResults = $HostResults | Where-Object { $_.DisplayName -like $Name -or $_.Publisher -like $Name }
    }

    # Remove duplicidades baseadas em Nome e Versão
    $HostResults = $HostResults | Sort-Object DisplayName -Unique

    Write-Host "  -> Encontrados: " -NoNewline; Write-Host "$($HostResults.Count) aplicativo(s)" -ForegroundColor Green

    foreach ($Item in $HostResults) {
        $AllResults.Add($Item)
    }
}

# Exibição resumida na tela (Top 25 se for muitos itens)
Write-Host ""
Write-Host "[Softwares Instalados Encontrados]" -ForegroundColor Yellow
$DisplayCount = [math]::Min($AllResults.Count, 25)
$AllResults | Select-Object -First $DisplayCount ComputerName, DisplayName, DisplayVersion, Publisher, Architecture | Format-Table -AutoSize

if ($AllResults.Count -gt 25) {
    Write-Host "  ... e mais $($AllResults.Count - 25) aplicativo(s) não exibidos na pré-visualização." -ForegroundColor DarkGray
    Write-Host "  Dica: Filtre por nome (-Name) ou exporte para CSV/HTML para ver a lista completa." -ForegroundColor DarkGray
}

# Exportação para CSV
if ($ExportCsv) {
    try {
        $AllResults | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding utf8
        Write-Host ""
        Write-Host "[OK] Relatório CSV salvo em: $ExportCsv" -ForegroundColor Green
    } catch {
        Write-Host ""
        Write-Host "[ERRO] Falha ao exportar CSV: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Exportação para HTML
if ($ExportHtml) {
    try {
        $RowsHtml = foreach ($App in $AllResults) {
            "<tr>
                <td>$([System.Net.WebUtility]::HtmlEncode($App.ComputerName))</td>
                <td><strong>$([System.Net.WebUtility]::HtmlEncode($App.DisplayName))</strong></td>
                <td>$([System.Net.WebUtility]::HtmlEncode($App.DisplayVersion))</td>
                <td>$([System.Net.WebUtility]::HtmlEncode($App.Publisher))</td>
                <td>$([System.Net.WebUtility]::HtmlEncode($App.Architecture))</td>
                <td>$([System.Net.WebUtility]::HtmlEncode($App.InstallDate))</td>
            </tr>"
        }

        $HtmlContent = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <title>Inventário de Softwares Instalados</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; margin: 20px; background-color: #f8fafc; color: #1e293b; }
        .header { background: linear-gradient(135deg, #0284c7, #0369a1); color: white; padding: 24px; border-radius: 8px; margin-bottom: 24px; }
        .header h1 { margin: 0; font-size: 24px; }
        .header p { margin: 6px 0 0 0; opacity: 0.9; font-size: 14px; }
        .card { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); margin-bottom: 20px; }
        table { width: 100%; border-collapse: collapse; font-size: 13px; }
        th { background-color: #f1f5f9; padding: 10px 12px; text-align: left; border-bottom: 2px solid #cbd5e1; font-weight: 600; }
        td { padding: 9px 12px; border-bottom: 1px solid #e2e8f0; }
        tr:hover { background-color: #f8fafc; }
        .badge { padding: 3px 8px; border-radius: 12px; font-size: 11px; font-weight: bold; background: #e0f2fe; color: #0369a1; }
    </style>
</head>
<body>
    <div class="header">
        <h1>📦 Inventário de Softwares Instalados</h1>
        <p>Gerado em $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss') | Total de Aplicações: $($AllResults.Count)</p>
    </div>
    <div class="card">
        <table>
            <thead>
                <tr>
                    <th>Host</th>
                    <th>Aplicativo</th>
                    <th>Versão</th>
                    <th>Fabricante / Publisher</th>
                    <th>Arquitetura</th>
                    <th>Data de Instalação</th>
                </tr>
            </thead>
            <tbody>
                $($RowsHtml -join "`n")
            </tbody>
        </table>
    </div>
</body>
</html>
"@
        $HtmlContent | Out-File -FilePath $ExportHtml -Encoding utf8
        Write-Host ""
        Write-Host "[OK] Relatório HTML gerado em: $ExportHtml" -ForegroundColor Green
    } catch {
        Write-Host ""
        Write-Host "[ERRO] Falha ao gerar HTML: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Retorna os objetos no pipeline para uso programático
return $AllResults
