<#
.SYNOPSIS
    Exibe um resumo operacional das máquinas virtuais Hyper-V no host.

.DESCRIPTION
    Coleta o estado de execução, uso de memória RAM, CPU, tempo de atividade
    e quantidade de checkpoints/snapshots criados para cada máquina virtual.
    Destaca VMs com snapshots antigos que podem esgotar o armazenamento do host.

.PARAMETER VMName
    Nome específico de uma VM para consultar (Padrão: todas as VMs).

.EXAMPLE
    .\Get-HyperVSummary.ps1

.EXAMPLE
    .\Get-HyperVSummary.ps1 -VMName "SRV-APP-01"
#>

[CmdletBinding()]
param(
    [string]$VMName = "*"
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "         RESUMO DE MÁQUINAS VIRTUAIS (HYPER-V)            " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Verificar se o módulo Hyper-V está disponível
if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    Write-Host "[!] O módulo 'Hyper-V' não está instalado ou habilitado neste computador." -ForegroundColor Yellow
    Write-Host "    Para habilitar a função Hyper-V no Windows Server:" -ForegroundColor DarkGray
    Write-Host "    Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    return
}

try {
    $VMs = Get-VM -Name $VMName -ErrorAction Stop
} catch {
    Write-Host "Erro ao consultar Hyper-V: $($_.Exception.Message)" -ForegroundColor Red
    return
}

if (-not $VMs -or $VMs.Count -eq 0) {
    Write-Host "Nenhuma máquina virtual encontrada com o filtro '$VMName'." -ForegroundColor Yellow
    Write-Host "==========================================================" -ForegroundColor Cyan
    return
}

Write-Host "Total de máquinas virtuais encontradas: $( $VMs.Count )" -ForegroundColor DarkGray
Write-Host ""

$Results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($VM in $VMs) {
    $StateColor = switch ($VM.State) {
        "Running" { "Green" }
        "Off"     { "DarkGray" }
        default   { "Yellow" }
    }

    $MemoryAssignedMB = [math]::Round($VM.MemoryAssigned / 1MB, 0)
    $MemoryDemandMB = [math]::Round($VM.MemoryDemand / 1MB, 0)

    # Contagem de checkpoints
    $Checkpoints = Get-VMSnapshot -VMName $VM.Name -ErrorAction SilentlyContinue
    $CheckpointCount = if ($Checkpoints) { $Checkpoints.Count } else { 0 }

    Write-Host "  VM: " -NoNewline
    Write-Host "$($VM.Name.PadRight(25))" -ForegroundColor White -NoNewline
    Write-Host " [$($VM.State.ToString().ToUpper())]" -ForegroundColor $StateColor -NoNewline
    Write-Host " - CPU: $($VM.CPUUsage)%" -ForegroundColor DarkCyan

    Write-Host "      Memória Alocada: $MemoryAssignedMB MB" -ForegroundColor DarkGray -NoNewline
    if ($VM.State -eq "Running") {
        Write-Host " (Demanda: $MemoryDemandMB MB) | Uptime: $($VM.Uptime)" -ForegroundColor DarkGray
    } else {
        Write-Host ""
    }

    if ($CheckpointCount -gt 0) {
        $CpColor = if ($CheckpointCount -ge 3) { "Red" } else { "Yellow" }
        Write-Host "      Checkpoints Ativos: $CheckpointCount snapshot(s) detectado(s)!" -ForegroundColor $CpColor
    }

    $Results.Add([PSCustomObject]@{
        NomeVM              = $VM.Name
        Estado              = $VM.State.ToString()
        CPU                 = "$($VM.CPUUsage)%"
        MemoriaAlocadaMB    = $MemoryAssignedMB
        MemoriaDemandaMB    = $MemoryDemandMB
        TempoAtividade      = $VM.Uptime.ToString()
        TotalCheckpoints    = $CheckpointCount
    })
    Write-Host "  ----------------------------------------------------" -ForegroundColor DarkGray
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Dica: Snapshots Hyper-V não substituem backup e consomem espaço crescente no disco físico." -ForegroundColor DarkGray
Write-Host "==========================================================" -ForegroundColor Cyan

return $Results
