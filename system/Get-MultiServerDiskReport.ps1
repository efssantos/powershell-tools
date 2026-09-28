<#
.SYNOPSIS
    Coleta e consolida o uso de espaço em disco de múltiplos servidores Windows simultaneamente.

.DESCRIPTION
    Script indispensável para a rotina diária de administração de infraestrutura:
    - Consulta o status de armazenamento de dezenas ou centenas de servidores em lote
    - Suporta entrada por lista de parâmetros (-ComputerName), arquivo de texto (-ComputerList) ou consulta ao AD (-FromAD)
    - Calcula Espaço Total (GB), Espaço Usado (GB), Espaço Livre (GB) e Porcentagem de Espaço Livre
    - Identifica volumes com espaço crítico (<= 10% livre) e alerta (<= 15% livre)
    - Suporta exportação para CSV (-ExportCsv) e dashboard HTML corporativo (-ExportHtml)
    - Retorna objetos estruturados no pipeline para integração com alertas por e-mail ou Slack/Teams.

.PARAMETER ComputerName
    Lista de nomes ou IPs dos servidores a serem auditados.

.PARAMETER ComputerList
    Caminho para arquivo .txt contendo um hostname de servidor por linha.

.PARAMETER FromAD
    Consulta automaticamente todos os servidores ativos registrados no Active Directory (Requer módulo RSAT ActiveDirectory).

.PARAMETER WarningPercent
    Limite em % para emitir status de ALERTA (Padrão: 15%).

.PARAMETER CriticalPercent
    Limite em % para emitir status CRÍTICO (Padrão: 10%).

.PARAMETER ExportCsv
    Caminho para arquivo CSV onde os dados consolidados serão gravados.

.PARAMETER ExportHtml
    Caminho para arquivo HTML com painel responsivo.

.EXAMPLE
    .\Get-MultiServerDiskReport.ps1 -ComputerName "SRV-DC01", "SRV-FS01", "SRV-SQL01"

.EXAMPLE
    .\Get-MultiServerDiskReport.ps1 -ComputerList "C:\Scripts\servidores.txt" -ExportHtml "C:\Temp\Relatorio_Discos.html"

.EXAMPLE
    .\Get-MultiServerDiskReport.ps1 -FromAD -WarningPercent 20 -CriticalPercent 10
#>

[CmdletBinding()]
param(
    [string[]]$ComputerName = @($env:COMPUTERNAME),
    [string]$ComputerList,
    [switch]$FromAD,
    [int]$WarningPercent = 15,
    [int]$CriticalPercent = 10,
    [string]$ExportCsv,
    [string]$ExportHtml
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "     CONSOLIDADOR DE ESPAÇO EM DISCO MULTI-SERVIDOR       " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Iniciando coleta de dados de armazenamento..." -ForegroundColor DarkGray
Write-Host ""

$TargetComputers = [System.Collections.Generic.List[string]]::new()

# Carregamento da lista de computadores
if ($ComputerList -and (Test-Path $ComputerList)) {
    Get-Content -Path $ComputerList | ForEach-Object {
        $Trimmed = $_.Trim()
        if ($Trimmed -and -not $Trimmed.StartsWith("#")) {
            $TargetComputers.Add($Trimmed)
        }
    }
} elseif ($FromAD) {
    if (Get-Module -ListAvailable -Name ActiveDirectory) {
        Import-Module ActiveDirectory -ErrorAction SilentlyContinue
        Write-Host "Consultando servidores no Active Directory..." -ForegroundColor DarkGray
        $AdServers = Get-ADComputer -Filter "OperatingSystem -like '*Server*'" -Properties OperatingSystem, Enabled | Where-Object { $_.Enabled } | Select-Object -ExpandProperty Name
        foreach ($Srv in $AdServers) { $TargetComputers.Add($Srv) }
    } else {
        Write-Host "[ALERTA] Módulo ActiveDirectory não está instalado. Usando host local." -ForegroundColor Yellow
        $TargetComputers.Add($env:COMPUTERNAME)
    }
} else {
    foreach ($C in $ComputerName) { $TargetComputers.Add($C.Trim()) }
}

$TargetComputers = $TargetComputers | Select-Object -Unique
Write-Host "Total de servidores na fila de auditoria: $($TargetComputers.Count)" -ForegroundColor White
Write-Host ""

$DiskReport = [System.Collections.Generic.List[PSCustomObject]]::new()
$TotalServersProcessed = 0
$OfflineServers = [System.Collections.Generic.List[string]]::new()

foreach ($Computer in $TargetComputers) {
    $TotalServersProcessed++
    Write-Host "[$TotalServersProcessed/$($TargetComputers.Count)] Consultando $Computer..." -ForegroundColor Cyan

    # Teste rápido de ping
    $IsOnline = $false
    if ($Computer -eq $env:COMPUTERNAME -or $Computer -eq "localhost" -or $Computer -eq ".") {
        $IsOnline = $true
    } else {
        $IsOnline = Test-Connection -ComputerName $Computer -Count 1 -Quiet -ErrorAction SilentlyContinue
    }

    if (-not $IsOnline) {
        Write-Host "  -> [OFFLINE] Servidor não respondeu ao ping." -ForegroundColor Red
        $OfflineServers.Add($Computer)
        continue
    }

    try {
        $IsLocal = ($Computer -eq $env:COMPUTERNAME -or $Computer -eq "localhost" -or $Computer -eq ".")
        $Disks = if ($IsLocal) {
            Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop
        } else {
            Get-CimInstance -ComputerName $Computer -ClassName Win32_LogicalDisk -Filter "DriveType=3" -OperationTimeoutSec 5 -ErrorAction Stop
        }

        foreach ($Disk in $Disks) {
            $TotalGB = [math]::Round($Disk.Size / 1GB, 2)
            $FreeGB = [math]::Round($Disk.FreeSpace / 1GB, 2)
            $UsedGB = [math]::Round($TotalGB - $FreeGB, 2)
            $FreePercent = if ($TotalGB -gt 0) { [math]::Round(($FreeGB / $TotalGB) * 100, 1) } else { 0 }

            $Status = if ($FreePercent -le $CriticalPercent -or $FreeGB -lt 5) {
                "CRÍTICO"
            } elseif ($FreePercent -le $WarningPercent) {
                "ALERTA"
            } else {
                "OK"
            }

            $StatusColor = switch ($Status) {
                "OK" { "Green" }
                "ALERTA" { "Yellow" }
                "CRÍTICO" { "Red" }
            }

            $Item = [PSCustomObject]@{
                Servidor      = $Computer
                Unidade       = $Disk.DeviceID
                Rotulo        = if ($Disk.VolumeName) { $Disk.VolumeName } else { "Sem Rótulo" }
                SistemaArq    = $Disk.FileSystem
                TamanhoTotal  = $TotalGB
                EspacoUsado   = $UsedGB
                EspacoLivre   = $FreeGB
                PorcentLivre  = $FreePercent
                Status        = $Status
            }
            $DiskReport.Add($Item)

            Write-Host "  Volume $($Disk.DeviceID) ($($Item.Rotulo)) : " -NoNewline -ForegroundColor White
            Write-Host "[$Status] " -NoNewline -ForegroundColor $StatusColor
            Write-Host "$FreeGB GB livres de $TotalGB GB ($FreePercent% livre)" -ForegroundColor DarkGray
        }
    } catch {
        Write-Host "  -> [FALHA WMI/CIM] Não foi possível obter dados: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Exibição tabular no console
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "              RESUMO GERAL DE DISCOS                      " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$DiskReport | Select-Object Servidor, Unidade, Rotulo, @{N='Total(GB)';E={$_.TamanhoTotal}}, @{N='Livre(GB)';E={$_.EspacoLivre}}, @{N='Livre(%)';E={"$($_.PorcentLivre)%"}}, Status | Format-Table -AutoSize

if ($OfflineServers.Count -gt 0) {
    Write-Host "Servidores Offline / Sem resposta ($($OfflineServers.Count)): $($OfflineServers -join ', ')" -ForegroundColor Red
}

# Exportação para CSV
if ($ExportCsv -and $DiskReport.Count -gt 0) {
    try {
        $DiskReport | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding utf8
        Write-Host ""
        Write-Host "[OK] Relatório CSV salvo em: $ExportCsv" -ForegroundColor Green
    } catch {
        Write-Host ""
        Write-Host "[ERRO] Falha ao exportar CSV: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# Exportação para HTML
if ($ExportHtml -and $DiskReport.Count -gt 0) {
    try {
        $TotalDisks = $DiskReport.Count
        $CritCount = ($DiskReport | Where-Object { $_.Status -eq "CRÍTICO" }).Count
        $AlertCount = ($DiskReport | Where-Object { $_.Status -eq "ALERTA" }).Count
        $OkCount = ($DiskReport | Where-Object { $_.Status -eq "OK" }).Count

        $RowsHtml = foreach ($D in $DiskReport) {
            $BadgeClass = switch ($D.Status) {
                "OK" { "badge-ok" }
                "ALERTA" { "badge-alert" }
                "CRÍTICO" { "badge-crit" }
            }

            $BarColor = switch ($D.Status) {
                "OK" { "#22c55e" }
                "ALERTA" { "#eab308" }
                "CRÍTICO" { "#ef4444" }
            }

            $UsedPercent = [math]::Round(100 - $D.PorcentLivre, 1)

            "<tr>
                <td><strong>$([System.Net.WebUtility]::HtmlEncode($D.Servidor))</strong></td>
                <td>$([System.Net.WebUtility]::HtmlEncode($D.Unidade))</td>
                <td>$([System.Net.WebUtility]::HtmlEncode($D.Rotulo))</td>
                <td>$($D.TamanhoTotal) GB</td>
                <td>$($D.EspacoUsado) GB</td>
                <td><strong>$($D.EspacoLivre) GB</strong></td>
                <td style='min-width: 140px;'>
                    <div style='background: #e2e8f0; border-radius: 4px; overflow: hidden; height: 16px; position: relative;'>
                        <div style='width: $UsedPercent%; background: $BarColor; height: 100%;'></div>
                    </div>
                    <small>$UsedPercent% usado ($($D.PorcentLivre)% livre)</small>
                </td>
                <td><span class='badge $BadgeClass'>$($D.Status)</span></td>
            </tr>"
        }

        $HtmlContent = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <title>Painel de Discos dos Servidores</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; margin: 20px; background-color: #f8fafc; color: #1e293b; }
        .header { background: linear-gradient(135deg, #1e3a8a, #0369a1); color: white; padding: 24px; border-radius: 8px; margin-bottom: 24px; }
        .header h1 { margin: 0; font-size: 24px; }
        .header p { margin: 6px 0 0 0; opacity: 0.9; font-size: 14px; }
        .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); gap: 15px; margin-bottom: 24px; }
        .stat-card { background: white; padding: 15px; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); text-align: center; }
        .stat-val { font-size: 24px; font-weight: bold; margin-top: 4px; }
        .card { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        table { width: 100%; border-collapse: collapse; font-size: 13px; }
        th { background-color: #f1f5f9; padding: 10px 12px; text-align: left; border-bottom: 2px solid #cbd5e1; font-weight: 600; }
        td { padding: 10px 12px; border-bottom: 1px solid #e2e8f0; vertical-align: middle; }
        tr:hover { background-color: #f8fafc; }
        .badge { padding: 4px 10px; border-radius: 12px; font-size: 11px; font-weight: bold; }
        .badge-ok { background: #dcfce7; color: #15803d; }
        .badge-alert { background: #fef9c3; color: #a16207; }
        .badge-crit { background: #fee2e2; color: #b91c1c; }
    </style>
</head>
<body>
    <div class="header">
        <h1>💾 Monitoramento Consolidado de Espaço em Disco</h1>
        <p>Auditados $($TargetComputers.Count) servidor(es) | Gerado em $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')</p>
    </div>

    <div class="stats-grid">
        <div class="stat-card"><div>Volumes Totais</div><div class="stat-val">$TotalDisks</div></div>
        <div class="stat-card"><div>Volumes Saudáveis</div><div class="stat-val" style="color: #15803d;">$OkCount</div></div>
        <div class="stat-card"><div>Volumes em Alerta</div><div class="stat-val" style="color: #a16207;">$AlertCount</div></div>
        <div class="stat-card"><div>Volumes Críticos</div><div class="stat-val" style="color: #b91c1c;">$CritCount</div></div>
    </div>

    <div class="card">
        <table>
            <thead>
                <tr>
                    <th>Servidor</th>
                    <th>Unidade</th>
                    <th>Rótulo</th>
                    <th>Tamanho Total</th>
                    <th>Espaço Usado</th>
                    <th>Espaço Livre</th>
                    <th>Uso (%)</th>
                    <th>Status</th>
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
        Write-Host "[OK] Painel HTML salvo em: $ExportHtml" -ForegroundColor Green
    } catch {
        Write-Host ""
        Write-Host "[ERRO] Falha ao exportar HTML: $($_.Exception.Message)" -ForegroundColor Red
    }
}

return $DiskReport
