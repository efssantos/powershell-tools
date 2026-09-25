<#
.SYNOPSIS
    Gera um relatório completo de saúde e recursos do servidor Windows.

.DESCRIPTION
    Exibe informações essenciais do sistema:
    - Identificação do SO, arquitetura e tempo de atividade (Uptime)
    - Utilização de CPU e núcleos
    - Memória RAM total, usada, livre e porcentagem de uso
    - Armazenamento em disco com alertas visuais de espaço crítico (<15%)
    - Top 5 processos consumidores de Memória e CPU
    - Suporte a exportação de relatório HTML.

.PARAMETER ExportHtml
    Gera um arquivo de relatório HTML com formatação profissional.

.PARAMETER OutputPath
    Caminho onde o arquivo HTML será salvo (Padrão: $HOME\Desktop\ServerHealthReport_<Data>.html).

.EXAMPLE
    .\Get-ServerHealthReport.ps1

.EXAMPLE
    .\Get-ServerHealthReport.ps1 -ExportHtml
#>

[CmdletBinding()]
param(
    [switch]$ExportHtml,
    [string]$OutputPath
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "         RELATÓRIO DE SAÚDE DO SERVIDOR (HEALTH CHECK)    " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Coletando métricas do sistema..." -ForegroundColor DarkGray

# 1. Informações Básicas do Sistema
$OS = Get-CimInstance -ClassName Win32_OperatingSystem
$Computer = Get-CimInstance -ClassName Win32_ComputerSystem
$Uptime = (Get-Date) - $OS.LastBootUpTime
$UptimeString = "{0} dias, {1} horas, {2} minutos" -f $Uptime.Days, $Uptime.Hours, $Uptime.Minutes

Write-Host ""
Write-Host "[1] Sistema & Uptime:" -ForegroundColor Yellow
Write-Host "  Hostname         : " -NoNewline; Write-Host $Computer.DNSHostName -ForegroundColor White
Write-Host "  Sistema Operacional: $($OS.Caption) ($($OS.OSArchitecture))" -ForegroundColor White
Write-Host "  Versão / Build   : $($OS.Version) (Build $($OS.BuildNumber))" -ForegroundColor DarkGray
Write-Host "  Domínio/Grupo    : $($Computer.Domain)" -ForegroundColor DarkGray
Write-Host "  Última Inicialização: $($OS.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor DarkGray
Write-Host "  Tempo de Atividade (Uptime): " -NoNewline; Write-Host $UptimeString -ForegroundColor Green

# 2. Utilização de Processador (CPU)
$CpuSample = Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property LoadPercentage -Average
$CpuAvg = [math]::Round($CpuSample.Average, 1)
$CpuCores = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property NumberOfCores -Sum).Sum

$CpuColor = if ($CpuAvg -lt 70) { "Green" } elseif ($CpuAvg -lt 90) { "Yellow" } else { "Red" }
Write-Host ""
Write-Host "[2] Processador (CPU):" -ForegroundColor Yellow
Write-Host "  Total de Núcleos : $CpuCores núcleos" -ForegroundColor White
Write-Host "  Uso Atual da CPU : " -NoNewline; Write-Host "$CpuAvg%" -ForegroundColor $CpuColor

# 3. Utilização de Memória (RAM)
$TotalRamGB = [math]::Round($OS.TotalVisibleMemorySize / 1MB, 2)
$FreeRamGB = [math]::Round($OS.FreePhysicalMemory / 1MB, 2)
$UsedRamGB = [math]::Round($TotalRamGB - $FreeRamGB, 2)
$RamPercent = [math]::Round(($UsedRamGB / $TotalRamGB) * 100, 1)

$RamColor = if ($RamPercent -lt 75) { "Green" } elseif ($RamPercent -lt 90) { "Yellow" } else { "Red" }
Write-Host ""
Write-Host "[3] Memória RAM:" -ForegroundColor Yellow
Write-Host "  Total Instalado  : $TotalRamGB GB" -ForegroundColor White
Write-Host "  Em Uso           : $UsedRamGB GB ($RamPercent%)" -ForegroundColor $RamColor
Write-Host "  Livre            : $FreeRamGB GB" -ForegroundColor White

# 4. Armazenamento em Disco
Write-Host ""
Write-Host "[4] Armazenamento (Volumes Locais):" -ForegroundColor Yellow
$Volumes = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DriveType=3"
$DiskReportList = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($Vol in $Volumes) {
    $TotalDiskGB = [math]::Round($Vol.Size / 1GB, 2)
    $FreeDiskGB = [math]::Round($Vol.FreeSpace / 1GB, 2)
    $UsedDiskGB = [math]::Round($TotalDiskGB - $FreeDiskGB, 2)
    $PercentFree = if ($TotalDiskGB -gt 0) { [math]::Round(($FreeDiskGB / $TotalDiskGB) * 100, 1) } else { 0 }

    $DiskStatus = "OK"
    $DColor = "Green"
    if ($PercentFree -lt 15) {
        $DiskStatus = "CRÍTICO"
        $DColor = "Red"
    } elseif ($PercentFree -lt 25) {
        $DiskStatus = "ALERTA"
        $DColor = "Yellow"
    }

    Write-Host "  Unidade $($Vol.DeviceID) ($($Vol.VolumeName)) : " -NoNewline
    Write-Host "[$DiskStatus]" -ForegroundColor $DColor -NoNewline
    Write-Host " - Livre: $FreeDiskGB GB de $TotalDiskGB GB ($PercentFree% livre)" -ForegroundColor White

    $DiskReportList.Add([PSCustomObject]@{
        Unidade     = $Vol.DeviceID
        Nome        = $Vol.VolumeName
        TotalGB     = $TotalDiskGB
        UsadoGB     = $UsedDiskGB
        LivreGB     = $FreeDiskGB
        PercentLivre = "$PercentFree%"
        Status      = $DiskStatus
    })
}

# 5. Top Processos Consumidores de RAM
Write-Host ""
Write-Host "[5] Top 5 Processos Consumidores de Memória:" -ForegroundColor Yellow
$TopMemory = Get-Process | Sort-Object -Property WorkingSet64 -Descending | Select-Object -First 5 |
    Select-Object Name, Id, @{Name="MemoriaMB"; Expression={[math]::Round($_.WorkingSet64 / 1MB, 1)}}

foreach ($Proc in $TopMemory) {
    Write-Host "  PID: $($Proc.Id.ToString().PadRight(6)) | $($Proc.Name.PadRight(25)) | $($Proc.MemoriaMB) MB" -ForegroundColor DarkCyan
}

# Exportar HTML se solicitado
if ($ExportHtml) {
    if (-not $OutputPath) {
        $OutputPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "ServerHealth_$($env:COMPUTERNAME)_$((Get-Date).ToString('yyyyMMdd_HHmm')).html"
    }

    $HtmlContent = @"
<!DOCTYPE html>
<html lang="pt-br">
<head>
    <meta charset="UTF-8">
    <title>Health Check - $($Computer.DNSHostName)</title>
    <style>
        body { font-family: Segoe UI, Tahoma, Geneva, Verdana, sans-serif; background-color: #f4f6f9; color: #333; margin: 20px; }
        h1, h2 { color: #0056b3; }
        .card { background: white; border-radius: 8px; padding: 20px; margin-bottom: 20px; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
        table { width: 100%; border-collapse: collapse; margin-top: 10px; }
        th, td { text-align: left; padding: 10px; border-bottom: 1px solid #ddd; }
        th { background-color: #f1f3f5; color: #495057; }
        .badge-ok { background-color: #28a745; color: white; padding: 4px 8px; border-radius: 4px; font-weight: bold; }
        .badge-alerta { background-color: #ffc107; color: black; padding: 4px 8px; border-radius: 4px; font-weight: bold; }
        .badge-critico { background-color: #dc3545; color: white; padding: 4px 8px; border-radius: 4px; font-weight: bold; }
        .metric { font-size: 1.2em; font-weight: bold; }
    </style>
</head>
<body>
    <h1>Relatório de Saúde do Servidor: $($Computer.DNSHostName)</h1>
    <p>Gerado em: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))</p>

    <div class="card">
        <h2>Visão Geral do Sistema</h2>
        <p><strong>Sistema Operacional:</strong> $($OS.Caption) ($($OS.OSArchitecture))</p>
        <p><strong>Uptime:</strong> $UptimeString (Desde $($OS.LastBootUpTime.ToString('yyyy-MM-dd HH:mm:ss')))</p>
        <p><strong>Domínio:</strong> $($Computer.Domain)</p>
    </div>

    <div class="card">
        <h2>Recursos Principais</h2>
        <p class="metric">Uso de CPU: $CpuAvg% ($CpuCores Núcleos)</p>
        <p class="metric">Uso de RAM: $UsedRamGB GB / $TotalRamGB GB ($RamPercent%)</p>
    </div>

    <div class="card">
        <h2>Armazenamento</h2>
        <table>
            <thead>
                <tr>
                    <th>Unidade</th><th>Nome</th><th>Total (GB)</th><th>Usado (GB)</th><th>Livre (GB)</th><th>% Livre</th><th>Status</th>
                </tr>
            </thead>
            <tbody>
                $($DiskReportList | ForEach-Object {
                    $BadgeClass = if ($_.Status -eq "OK") { "badge-ok" } elseif ($_.Status -eq "ALERTA") { "badge-alerta" } else { "badge-critico" }
                    "<tr><td>$($_.Unidade)</td><td>$($_.Nome)</td><td>$($_.TotalGB)</td><td>$($_.UsadoGB)</td><td>$($_.LivreGB)</td><td>$($_.PercentLivre)</td><td><span class='$BadgeClass'>$($_.Status)</span></td></tr>"
                } -join "`n")
            </tbody>
        </table>
    </div>
</body>
</html>
"@
    Set-Content -Path $OutputPath -Value $HtmlContent -Encoding UTF8
    Write-Host ""
    Write-Host "Relatório HTML salvo com sucesso em: $OutputPath" -ForegroundColor Green
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Verificação finalizada com sucesso." -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
