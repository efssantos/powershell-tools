<#
.SYNOPSIS
    Otimiza o desempenho de computadores de usuários finais (Desktops e Notebooks).

.DESCRIPTION
    Executa rotinas de aceleração e manutenção preventiva:
    - Limpa caches de navegadores (Edge e Chrome), caches de miniaturas (Thumbnails) e cache de Otimização de Entrega do Windows (Delivery Optimization)
    - Limpa arquivos temporários do usuário e do sistema
    - Analisa e lista programas que iniciam com o Windows (Startup items) impactando o tempo de boot
    - Executa comando TRIM em unidades de estado sólido (SSD) para restaurar a velocidade de escrita
    - Limpa o cache DNS do sistema
    - Verifica o plano de energia atual (avisa caso esteja em modo 'Economia de Energia') com opção para ajustar para Alto Desempenho

.PARAMETER SetHighPerformance
    Altera o plano de energia do Windows para Alto Desempenho (High Performance).

.PARAMETER SkipSsdTrim
    Ignora a execução do comando TRIM nos discos SSD.

.EXAMPLE
    .\Optimize-WorkstationPerformance.ps1

.EXAMPLE
    .\Optimize-WorkstationPerformance.ps1 -SetHighPerformance
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$SetHighPerformance,
    [switch]$SkipSsdTrim
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "     OTIMIZAÇÃO DE PERFORMANCE DE WORKSTATIONS           " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Iniciando otimização do sistema... Aguarde." -ForegroundColor DarkGray
Write-Host ""

$Script:FreedBytes = 0

function Safe-CleanPath {
    param([string]$Path, [string]$Label)
    if (Test-Path $Path -ErrorAction SilentlyContinue) {
        Write-Host "  Limpando $Label..." -ForegroundColor Yellow -NoNewline
        $Items = Get-ChildItem -Path $Path -Recurse -File -Force -ErrorAction SilentlyContinue
        $Count = 0
        $Bytes = 0
        foreach ($File in $Items) {
            try {
                $Len = $File.Length
                Remove-Item -Path $File.FullName -Force -ErrorAction Stop
                $Bytes += $Len
                $Count++
            } catch {}
        }
        $MB = [math]::Round($Bytes / 1MB, 2)
        $Script:FreedBytes += $Bytes
        Write-Host " [OK - $Count arquivos, $MB MB liberados]" -ForegroundColor Green
    }
}

# 1. Limpeza de Caches de Navegadores (Apenas Cache, preservando logins, histórico e senhas)
Write-Host "[1] Limpeza de Caches de Navegadores & Miniaturas:" -ForegroundColor Yellow

$ChromeCache = "$env:LOCALAPPDATA\Google\Chrome\User Data\Default\Cache\Cache_Data"
$EdgeCache   = "$env:LOCALAPPDATA\Microsoft\Edge\User Data\Default\Cache\Cache_Data"
$ThumbCache  = "$env:LOCALAPPDATA\Microsoft\Windows\Explorer"

Safe-CleanPath -Path $ChromeCache -Label "Cache do Google Chrome"
Safe-CleanPath -Path $EdgeCache -Label "Cache do Microsoft Edge"

# Miniaturas antigas .db
if (Test-Path $ThumbCache) {
    Get-ChildItem -Path $ThumbCache -Filter "thumbcache_*.db" -File -Force -ErrorAction SilentlyContinue |
        ForEach-Object {
            try {
                $Script:FreedBytes += $_.Length
                Remove-Item $_.FullName -Force -ErrorAction Stop
            } catch {}
        }
    Write-Host "  Limpeza de arquivos de miniaturas (Thumbnails) concluída." -ForegroundColor Green
}

# 2. Cache de Otimização de Entrega do Windows (Delivery Optimization)
Write-Host ""
Write-Host "[2] Cache do Windows Delivery Optimization:" -ForegroundColor Yellow
$DoCache = "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
Safe-CleanPath -Path $DoCache -Label "Cache de atualizações P2P (Delivery Optimization)"

# 3. Limpeza de Temporários do Usuário e Sistema
Write-Host ""
Write-Host "[3] Arquivos Temporários (%TEMP% & Windows Temp):" -ForegroundColor Yellow
Safe-CleanPath -Path "$env:LOCALAPPDATA\Temp" -Label "Temp do Usuário Atual"
Safe-CleanPath -Path "$env:SystemRoot\Temp" -Label "Windows Temp"

# 4. Limpeza de Cache DNS
Write-Host ""
Write-Host "[4] Cache de Resolução DNS:" -ForegroundColor Yellow
try {
    Clear-DnsClientCache
    Write-Host "  Cache DNS limpo com sucesso." -ForegroundColor Green
} catch {
    Write-Host "  Falha ao limpar cache DNS: $($_.Exception.Message)" -ForegroundColor Red
}

# 5. Otimização de Discos SSD (TRIM)
if (-not $SkipSsdTrim) {
    Write-Host ""
    Write-Host "[5] Otimização de Discos SSD (TRIM):" -ForegroundColor Yellow
    $Disks = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.MediaType -eq "SSD" }
    if ($Disks) {
        Write-Host "  Discos SSD detectados. Executando comando de ReTrim no drive C:..." -ForegroundColor DarkGray
        try {
            Optimize-Volume -DriveLetter C -ReTrim -ErrorAction Stop | Out-Null
            Write-Host "  -> Comando TRIM executado com sucesso no volume C:!" -ForegroundColor Green
        } catch {
            Write-Host "  -> Não foi possível executar ReTrim (ou volume não suporta): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    } else {
        Write-Host "  Nenhum disco do tipo SSD identificado para operação TRIM." -ForegroundColor DarkGray
    }
}

# 6. Verificação do Plano de Energia
Write-Host ""
Write-Host "[6] Plano de Energia do Windows:" -ForegroundColor Yellow
$ActiveScheme = powercfg /getactivescheme
Write-Host "  Plano Atual: $ActiveScheme" -ForegroundColor White

if ($ActiveScheme -match "Economia de energia|Power saver") {
    Write-Host "  ALERTA: O computador está em modo de Economia de Energia, o que reduz o clock do processador!" -ForegroundColor Yellow
}

if ($SetHighPerformance) {
    # GUID do plano Alto Desempenho
    $HighPerfGuid = "8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c"
    powercfg /setactive $HighPerfGuid
    Write-Host "  -> Plano de energia alterado para ALTO DESEMPENHO com sucesso!" -ForegroundColor Green
}

# 7. Diagnóstico de Inicialização (Startup)
Write-Host ""
Write-Host "[7] Programas que iniciam com o Windows (Startup):" -ForegroundColor Yellow
$StartupItems = Get-CimInstance -ClassName Win32_StartupCommand -ErrorAction SilentlyContinue

if ($StartupItems) {
    Write-Host "  Total de programas na inicialização: $( $StartupItems.Count )" -ForegroundColor DarkGray
    foreach ($Item in $StartupItems | Select-Object -First 8) {
        Write-Host "  - $($Item.Name.PadRight(25)) | $($Item.Command)" -ForegroundColor DarkCyan
    }
    if ($StartupItems.Count -gt 8) {
        Write-Host "  ... e mais $( $StartupItems.Count - 8 ) programas." -ForegroundColor DarkGray
    }
} else {
    Write-Host "  Nenhum item comum de inicialização encontrado." -ForegroundColor DarkGray
}

$TotalFreedMB = [math]::Round($Script:FreedBytes / 1MB, 2)
$TotalFreedGB = [math]::Round($Script:FreedBytes / 1GB, 2)

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Otimização concluída!" -ForegroundColor Cyan
Write-Host "Espaço em disco recuperado: $TotalFreedMB MB ($TotalFreedGB GB)" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
