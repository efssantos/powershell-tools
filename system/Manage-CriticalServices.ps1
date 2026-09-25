<#
.SYNOPSIS
    Monitora e gerencia serviços essenciais do Windows Server.

.DESCRIPTION
    Verifica o status de execução e o tipo de inicialização de serviços críticos
    de infraestrutura (RDP, WinRM, Spooler, W32Time, Windows Update, etc.).
    Pode reiniciar automaticamente serviços que deveriam estar rodando.

.PARAMETER AutoRestart
    Tenta iniciar automaticamente qualquer serviço configurado como 'Automatic'
    que esteja atualmente no estado 'Stopped'.

.PARAMETER CustomServices
    Lista adicional ou personalizada de nomes de serviços para monitorar.

.EXAMPLE
    .\Manage-CriticalServices.ps1

.EXAMPLE
    .\Manage-CriticalServices.ps1 -AutoRestart
#>

[CmdletBinding()]
param(
    [switch]$AutoRestart,
    [string[]]$CustomServices
)

# Lista padrão de serviços críticos de infraestrutura
$DefaultCriticalServices = @(
    "LanmanServer",      # Compartilhamento de arquivos (SMB)
    "LanmanWorkstation", # Cliente de rede
    "TermService",       # RDP / Conexão de Área de Trabalho Remota
    "WinRM",             # Gerenciamento remoto via PowerShell
    "W32Time",           # Sincronização de horário (NTP)
    "EventLog",          # Log de Eventos do Windows
    "Dnscache",          # Cliente DNS
    "Dhcp",              # Cliente DHCP
    "Spooler",           # Spooler de impressão
    "wuauserv",          # Windows Update
    "MpsSvc"             # Firewall do Windows Defender
)

$TargetServices = if ($CustomServices) { $CustomServices } else { $DefaultCriticalServices }

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "       MONITORAMENTO DE SERVIÇOS CRÍTICOS DO SERVIDOR     " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Verificando $( $TargetServices.Count ) serviços essenciais..." -ForegroundColor DarkGray
Write-Host ""

$Results = [System.Collections.Generic.List[PSCustomObject]]::new()
$AttentionNeeded = 0

foreach ($SvcName in $TargetServices) {
    $Svc = Get-Service -Name $SvcName -ErrorAction SilentlyContinue

    if (-not $Svc) {
        Write-Host "  [-] Serviço não encontrado: $SvcName" -ForegroundColor DarkGray
        continue
    }

    # Obter tipo de inicialização via WMI/CIM
    $CimSvc = Get-CimInstance -ClassName Win32_Service -Filter "Name='$SvcName'" -ErrorAction SilentlyContinue
    $StartMode = if ($CimSvc) { $CimSvc.StartMode } else { "Desconhecido" }

    $StatusColor = switch ($Svc.Status) {
        "Running" { "Green" }
        "Stopped" { "Red" }
        default   { "Yellow" }
    }

    $StatusLabel = switch ($Svc.Status) {
        "Running" { "[EM EXECUÇÃO]" }
        "Stopped" { "[PARADO]     " }
        default   { "[$($Svc.Status.ToString().ToUpper())]" }
    }

    Write-Host "  $StatusLabel " -ForegroundColor $StatusColor -NoNewline
    Write-Host "$($Svc.DisplayName) " -ForegroundColor White -NoNewline
    Write-Host "($($Svc.Name) - Startup: $StartMode)" -ForegroundColor DarkGray

    $ShouldBeRunning = ($StartMode -eq "Auto" -or $StartMode -eq "Automatic") -and ($Svc.Status -ne "Running")
    $ActionTaken = "Nenhuma"

    if ($ShouldBeRunning) {
        $AttentionNeeded++
        Write-Host "      ALERTA: Serviço configurado como Automático, porém está Parado!" -ForegroundColor Yellow

        if ($AutoRestart) {
            Write-Host "      -> Tentando iniciar serviço..." -ForegroundColor Cyan -NoNewline
            try {
                Start-Service -Name $Svc.Name -ErrorAction Stop
                Write-Host " [SUCESSO]" -ForegroundColor Green
                $ActionTaken = "Iniciado com sucesso"
            } catch {
                Write-Host " [FALHA: $($_.Exception.Message)]" -ForegroundColor Red
                $ActionTaken = "Falha ao iniciar: $($_.Exception.Message)"
            }
        }
    }

    $Results.Add([PSCustomObject]@{
        NomeExibicao    = $Svc.DisplayName
        NomeServico     = $Svc.Name
        Status          = $Svc.Status.ToString()
        ModoInicio      = $StartMode
        RequerAtencao   = $ShouldBeRunning
        AcaoExecutada   = $ActionTaken
    })
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
if ($AttentionNeeded -gt 0) {
    Write-Host "Atenção: $AttentionNeeded serviço(s) com inicialização automática estavam parados." -ForegroundColor Yellow
    if (-not $AutoRestart) {
        Write-Host "Dica: Execute com o parâmetro -AutoRestart para tentar reiniciá-los automaticamente." -ForegroundColor DarkGray
    }
} else {
    Write-Host "Todos os serviços automáticos verificados estão operando normalmente!" -ForegroundColor Green
}
Write-Host "==========================================================" -ForegroundColor Cyan

return $Results
