<#
.SYNOPSIS
    Realiza um diagnóstico completo e rápido da estação de trabalho do usuário final (Desktop/Notebook).

.DESCRIPTION
    Coleta informações vitais de hardware, sistema, armazenamento, segurança e rede:
    - Fabricante, Modelo, Número de Série (Tag/Service Tag) e Usuário logado
    - Versão e Build do Windows, Uptime e verificação de Reinicialização Pendente (Pending Reboot)
    - Saúde e tipo dos discos (SSD / NVMe / HDD, status SMART)
    - Saúde da Bateria (se for Notebook: capacidade projetada vs atual, desgaste)
    - Segurança: Status do Windows Defender (Proteção em tempo real e atualização de assinaturas) e BitLocker
    - Histórico recente de Telas Azuis (BSOD / Minidumps)
    - Conexão de rede ativa (Ethernet ou Wi-Fi com força do sinal)

.PARAMETER ExportHtml
    Gera um relatório HTML formatado com o diagnóstico.

.PARAMETER OutputPath
    Caminho de saída para o arquivo HTML gerado.

.EXAMPLE
    .\Get-WorkstationDiagnostics.ps1

.EXAMPLE
    .\Get-WorkstationDiagnostics.ps1 -ExportHtml
#>

[CmdletBinding()]
param(
    [switch]$ExportHtml,
    [string]$OutputPath
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "     DIAGNÓSTICO RÁPIDO DE WORKSTATION / ENDPOINT         " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Coletando dados do endpoint em tempo real..." -ForegroundColor DarkGray
Write-Host ""

# 1. Informações de Hardware & Identificação
$ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
$Bios = Get-CimInstance -ClassName Win32_BIOS
$OS = Get-CimInstance -ClassName Win32_OperatingSystem

$LoggedUser = if ($ComputerSystem.UserName) { $ComputerSystem.UserName } else { [System.Security.Principal.WindowsIdentity]::GetCurrent().Name }
$SerialNumber = $Bios.SerialNumber
$Manufacturer = $ComputerSystem.Manufacturer
$Model = $ComputerSystem.Model

Write-Host "[1] Identificação & Hardware:" -ForegroundColor Yellow
Write-Host "  Equipamento     : $Manufacturer - $Model" -ForegroundColor White
Write-Host "  Número de Série : " -NoNewline; Write-Host $SerialNumber -ForegroundColor Green
Write-Host "  Nome do Host    : $($env:COMPUTERNAME)" -ForegroundColor White
Write-Host "  Usuário Logado  : " -NoNewline; Write-Host $LoggedUser -ForegroundColor Cyan

# 2. Sistema Operacional & Reinicialização Pendente
$Uptime = (Get-Date) - $OS.LastBootUpTime
$UptimeFormatted = "{0} dias, {1}h {2}m" -f $Uptime.Days, $Uptime.Hours, $Uptime.Minutes

# Checagem de Pending Reboot (Component Based Servicing, Windows Update, Session Manager)
$PendingReboot = $false
$RebootReasons = [System.Collections.Generic.List[string]]::new()

if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") {
    $PendingReboot = $true; $RebootReasons.Add("Component Based Servicing")
}
if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") {
    $PendingReboot = $true; $RebootReasons.Add("Windows Update")
}
$SessionManager = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager" -Name "PendingFileRenameOperations" -ErrorAction SilentlyContinue
if ($SessionManager -and $SessionManager.PendingFileRenameOperations) {
    $PendingReboot = $true; $RebootReasons.Add("Arquivos Pendentes de Renomeação")
}

Write-Host ""
Write-Host "[2] Sistema Operacional & Status:" -ForegroundColor Yellow
Write-Host "  Edição          : $($OS.Caption) ($($OS.OSArchitecture))" -ForegroundColor White
Write-Host "  Versão / Build  : $($OS.Version) (Build $($OS.BuildNumber))" -ForegroundColor DarkGray
Write-Host "  Tempo de Uptime : " -NoNewline
$UptimeColor = if ($Uptime.Days -ge 7) { "Yellow" } else { "Green" }
Write-Host "$UptimeFormatted" -ForegroundColor $UptimeColor
if ($Uptime.Days -ge 7) {
    Write-Host "      (Aviso: O computador não é reiniciado há mais de 7 dias!)" -ForegroundColor Yellow
}

Write-Host "  Reboot Pendente : " -NoNewline
if ($PendingReboot) {
    Write-Host "[SIM - $( $RebootReasons -join ', ' )]" -ForegroundColor Red
} else {
    Write-Host "[NÃO]" -ForegroundColor Green
}

# 3. Saúde do Armazenamento (Discos Físicos & SMART)
Write-Host ""
Write-Host "[3] Armazenamento Físico & Saúde SMART:" -ForegroundColor Yellow
$PhysicalDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue

if ($PhysicalDisks) {
    foreach ($Disk in $PhysicalDisks) {
        $HealthStatus = $Disk.HealthStatus
        $HColor = if ($HealthStatus -eq "Healthy") { "Green" } else { "Red" }
        $SizeGB = [math]::Round($Disk.Size / 1GB, 1)

        Write-Host "  Disco #$($Disk.DeviceId): $($Disk.FriendlyName)" -ForegroundColor White
        Write-Host "    Tipo de Mídia : $($Disk.MediaType) ($($Disk.BusType)) | Tamanho: $SizeGB GB" -ForegroundColor DarkGray
        Write-Host "    Status SMART  : " -NoNewline
        Write-Host "[$HealthStatus - $($Disk.OperationalStatus)]" -ForegroundColor $HColor
    }
} else {
    Write-Host "  Não foi possível obter dados detalhados dos discos físicos." -ForegroundColor DarkGray
}

# 4. Saúde da Bateria (Se for Notebook)
$Battery = Get-CimInstance -ClassName Win32_Battery -ErrorAction SilentlyContinue
if ($Battery) {
    Write-Host ""
    Write-Host "[4] Diagnóstico de Bateria (Notebook):" -ForegroundColor Yellow
    $BatteryPercent = $Battery.EstimatedChargeRemaining
    $BatteryStatus = switch ($Battery.BatteryStatus) {
        1 { "Descarregando" }
        2 { "Conectado na Tomada (Carregando/Cheio)" }
        default { "Em uso" }
    }

    Write-Host "  Carga Atual     : " -NoNewline
    $BColor = if ($BatteryPercent -gt 30) { "Green" } else { "Yellow" }
    Write-Host "$BatteryPercent% ($BatteryStatus)" -ForegroundColor $BColor

    # Cálculo de desgaste se disponível via WmiMonitor
    try {
        $FullCharge = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop).FullChargedCapacity
        $DesignCap = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction Stop).DesignedCapacity
        if ($FullCharge -and $DesignCap -and $DesignCap -gt 0) {
            $WearRatio = [math]::Round(($FullCharge / $DesignCap) * 100, 1)
            $WearColor = if ($WearRatio -ge 80) { "Green" } elseif ($WearRatio -ge 60) { "Yellow" } else { "Red" }
            Write-Host "  Saúde da Bateria: " -NoNewline
            Write-Host "$WearRatio% da capacidade original de fábrica" -ForegroundColor $WearColor
        }
    } catch {
        # Dados de WmiMonitor opcionais
    }
}

# 5. Segurança & Proteção de Endpoint
Write-Host ""
Write-Host "[5] Segurança & Criptografia:" -ForegroundColor Yellow

# Windows Defender
try {
    $MpPref = Get-MpComputerStatus -ErrorAction Stop
    $RTP = if ($MpPref.RealTimeProtectionEnabled) { "ATIVADA" } else { "DESATIVADA" }
    $RTPColor = if ($MpPref.RealTimeProtectionEnabled) { "Green" } else { "Red" }
    $DefAgeDays = (New-TimeSpan -Start $MpPref.AntivirusSignatureLastUpdated -End (Get-Date)).Days

    Write-Host "  Defender Real-Time : " -NoNewline; Write-Host "[$RTP]" -ForegroundColor $RTPColor
    Write-Host "  Definições Antivírus: Atualizadas em $($MpPref.AntivirusSignatureLastUpdated.ToString('yyyy-MM-dd')) ($DefAgeDays dias atrás)" -ForegroundColor DarkGray
} catch {
    Write-Host "  Defender           : Informações não acessíveis ou antivírus de terceiros em execução." -ForegroundColor DarkGray
}

# BitLocker no Drive C:
try {
    $BitLockerC = Get-BitLockerVolume -MountPoint "C:" -ErrorAction Stop
    $BLStatus = if ($BitLockerC.ProtectionStatus -eq "On") { "PROTEGIDO (Criptografado)" } else { "NÃO PROTEGIDO" }
    $BLColor = if ($BitLockerC.ProtectionStatus -eq "On") { "Green" } else { "Yellow" }
    Write-Host "  BitLocker (C:)     : " -NoNewline; Write-Host "[$BLStatus]" -ForegroundColor $BLColor
} catch {
    Write-Host "  BitLocker          : Não configurado ou sem suporte neste sistema." -ForegroundColor DarkGray
}

# 6. Histórico de Telas Azuis (BSOD)
Write-Host ""
Write-Host "[6] Telas Azuis Recentes (BSOD / Minidumps):" -ForegroundColor Yellow
$DumpPath = "$env:SystemRoot\Minidump"
if (Test-Path $DumpPath) {
    $Dumps = Get-ChildItem -Path $DumpPath -Filter "*.dmp" -ErrorAction SilentlyContinue |
        Sort-Object -Property LastWriteTime -Descending | Select-Object -First 3

    if ($Dumps) {
        Write-Host "  ALERTA: Foram detectados $($Dumps.Count) arquivo(s) de despejo recente(s):" -ForegroundColor Red
        foreach ($d in $Dumps) {
            Write-Host "    - $($d.Name) ($($d.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')))" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Nenhum travamento recente (sem arquivos minidump)." -ForegroundColor Green
    }
} else {
    Write-Host "  Nenhum minidump encontrado." -ForegroundColor Green
}

# 7. Conectividade de Rede
Write-Host ""
Write-Host "[7] Conexão de Rede Atual:" -ForegroundColor Yellow
$ActiveNet = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1

if ($ActiveNet) {
    $IP = (Get-NetIPAddress -InterfaceIndex $ActiveNet.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress
    Write-Host "  Interface: $($ActiveNet.Name) ($($ActiveNet.InterfaceDescription))" -ForegroundColor White
    Write-Host "  IPv4     : $IP | Velocidade: $($ActiveNet.LinkSpeed)" -ForegroundColor Cyan

    # Se for Wi-Fi, buscar SSID e sinal
    if ($ActiveNet.PhysicalMediaType -match "Native 802.11" -or $ActiveNet.Name -match "Wi-Fi|Wireless") {
        $WlanRaw = netsh wlan show interfaces
        $Ssid = ($WlanRaw | Where-Object { $_ -match '^\s*SSID\s*:\s*(.+)$' } | ForEach-Object { $Matches[1].Trim() })
        $Signal = ($WlanRaw | Where-Object { $_ -match '^\s*Sinal\s*:\s*(.+)$' -or $_ -match '^\s*Signal\s*:\s*(.+)$' } | ForEach-Object { $Matches[1].Trim() })
        if ($Ssid) {
            Write-Host "  Wi-Fi SSID: $Ssid | Força do Sinal: $Signal" -ForegroundColor Green
        }
    }
} else {
    Write-Host "  Nenhum adaptador de rede com status Up." -ForegroundColor Red
}

# Exportar HTML se solicitado
if ($ExportHtml) {
    if (-not $OutputPath) {
        $OutputPath = Join-Path ([Environment]::GetFolderPath("Desktop")) "Diagnostico_$($env:COMPUTERNAME)_$((Get-Date).ToString('yyyyMMdd_HHmm')).html"
    }

    $Html = @"
<!DOCTYPE html>
<html lang="pt-br">
<head>
    <meta charset="UTF-8">
    <title>Diagnóstico Workstation - $($env:COMPUTERNAME)</title>
    <style>
        body { font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; background: #f8fafc; color: #1e293b; padding: 20px; }
        .container { max-width: 900px; margin: 0 auto; }
        .card { background: white; border-radius: 8px; padding: 20px; margin-bottom: 16px; border: 1px solid #e2e8f0; box-shadow: 0 1px 3px rgba(0,0,0,0.05); }
        h1 { color: #0284c7; }
        h2 { color: #334155; font-size: 1.2em; border-bottom: 2px solid #f1f5f9; padding-bottom: 8px; }
        .row { display: flex; justify-content: space-between; padding: 6px 0; border-bottom: 1px solid #f8fafc; }
        .label { font-weight: 600; color: #64748b; }
        .badge { padding: 4px 8px; border-radius: 4px; font-weight: bold; font-size: 0.9em; }
        .badge-green { background: #dcfce7; color: #15803d; }
        .badge-red { background: #fee2e2; color: #b91c1c; }
        .badge-yellow { background: #fef9c3; color: #a16207; }
    </style>
</head>
<body>
    <div class="container">
        <h1>Diagnóstico de Endpoint: $($env:COMPUTERNAME)</h1>
        <p>Gerado em: $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) | Usuário: $LoggedUser</p>

        <div class="card">
            <h2>Hardware & Identificação</h2>
            <div class="row"><span class="label">Fabricante / Modelo</span><span>$Manufacturer - $Model</span></div>
            <div class="row"><span class="label">Número de Série</span><span><strong>$SerialNumber</strong></span></div>
            <div class="row"><span class="label">Sistema Operacional</span><span>$($OS.Caption) ($($OS.Version))</span></div>
            <div class="row"><span class="label">Uptime</span><span>$UptimeFormatted</span></div>
            <div class="row"><span class="label">Reinicialização Pendente</span><span>$(if ($PendingReboot) { "<span class='badge badge-red'>SIM</span>" } else { "<span class='badge badge-green'>NÃO</span>" })</span></div>
        </div>
    </div>
</body>
</html>
"@
    Set-Content -Path $OutputPath -Value $Html -Encoding UTF8
    Write-Host ""
    Write-Host "Relatório exportado com sucesso: $OutputPath" -ForegroundColor Green
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Diagnóstico do endpoint concluído com sucesso." -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
