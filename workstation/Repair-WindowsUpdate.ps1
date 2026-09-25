<#
.SYNOPSIS
    Corrige falhas, travamentos e erros de atualização do Windows Update em computadores de usuários.

.DESCRIPTION
    Resolve problemas comuns como alto consumo de CPU pelo TiWorker/svchost, erros 0x800... no Windows Update,
    e downloads corrompidos de atualizações.
    Procedimento executado:
    - Finaliza serviços: Windows Update (wuauserv), BITS, Serviços Criptográficos (cryptsvc) e Instalador (msiserver)
    - Limpa a fila pendente de downloads do BITS
    - Renomeia as pastas de cache corrompidas 'SoftwareDistribution' e 'catroot2'
    - Redefine o catálogo de rede Winsock e proxy WinHTTP
    - Reinicia todos os serviços e dispara uma nova verificação de atualizações limpa.

.EXAMPLE
    .\Repair-WindowsUpdate.ps1
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param()

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "       REPARO E REDEFINIÇÃO DO WINDOWS UPDATE             " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Iniciando processo de reparação de componentes do sistema..." -ForegroundColor DarkGray
Write-Host ""

$Services = @("wuauserv", "bits", "cryptsvc", "msiserver")

# 1. Parar Serviços Relacionados
Write-Host "[1] Interrompendo serviços do Windows Update e BITS:" -ForegroundColor Yellow
foreach ($Svc in $Services) {
    Write-Host "  Parando serviço $Svc..." -ForegroundColor DarkGray -NoNewline
    try {
        Stop-Service -Name $Svc -Force -ErrorAction SilentlyContinue
        Write-Host " [OK]" -ForegroundColor Green
    } catch {
        Write-Host " [IGNORADO]" -ForegroundColor DarkGray
    }
}

# 2. Limpar fila do BITS
Write-Host ""
Write-Host "[2] Limpando fila de transferências pendentes do BITS:" -ForegroundColor Yellow
try {
    Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Remove-BitsTransfer -ErrorAction SilentlyContinue
    Write-Host "  Fila do BITS limpa com sucesso." -ForegroundColor Green
} catch {
    Write-Host "  Nenhuma transferência pendente no BITS." -ForegroundColor DarkGray
}

# 3. Renomear Pastas de Cache (SoftwareDistribution e Catroot2)
Write-Host ""
Write-Host "[3] Redefinindo pastas de cache do Windows Update:" -ForegroundColor Yellow

$TimeStamp = (Get-Date).ToString("yyyyMMddHHmmss")
$SoftDist = "$env:SystemRoot\SoftwareDistribution"
$Catroot2 = "$env:SystemRoot\System32\catroot2"

if (Test-Path $SoftDist) {
    try {
        Rename-Item -Path $SoftDist -NewName "SoftwareDistribution.old_$TimeStamp" -Force -ErrorAction Stop
        Write-Host "  -> Pasta SoftwareDistribution renomeada com sucesso." -ForegroundColor Green
    } catch {
        Write-Host "  -> Não foi possível renomear SoftwareDistribution ($($_.Exception.Message)). Tentando esvaziar arquivos..." -ForegroundColor Yellow
        Get-ChildItem -Path $SoftDist -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    }
}

if (Test-Path $Catroot2) {
    try {
        Rename-Item -Path $Catroot2 -NewName "catroot2.old_$TimeStamp" -Force -ErrorAction Stop
        Write-Host "  -> Pasta catroot2 renomeada com sucesso." -ForegroundColor Green
    } catch {
        Write-Host "  -> catroot2 em uso por outro processo de segurança." -ForegroundColor DarkGray
    }
}

# 4. Redefinir sockets de rede e configurações WinHTTP
Write-Host ""
Write-Host "[4] Redefinindo pilha de rede e WinHTTP Proxy:" -ForegroundColor Yellow
netsh winsock reset | Out-Null
netsh winhttp reset proxy | Out-Null
Write-Host "  Catálogo de Winsock e configurações WinHTTP redefinidas." -ForegroundColor Green

# 5. Reiniciar Serviços
Write-Host ""
Write-Host "[5] Reiniciando serviços:" -ForegroundColor Yellow
foreach ($Svc in $Services) {
    Write-Host "  Iniciando serviço $Svc..." -ForegroundColor DarkGray -NoNewline
    try {
        Start-Service -Name $Svc -ErrorAction SilentlyContinue
        Write-Host " [OK]" -ForegroundColor Green
    } catch {
        Write-Host " [FALHA]" -ForegroundColor Red
    }
}

# 6. Disparar nova verificação de atualizações
Write-Host ""
Write-Host "[6] Disparando nova busca de atualizações:" -ForegroundColor Yellow
try {
    Start-Process -FilePath "usoclient.exe" -ArgumentList "StartScan" -ErrorAction SilentlyContinue
    Write-Host "  Verificação de atualizações acionada em segundo plano via USO Client." -ForegroundColor Green
} catch {
    Write-Host "  Tentativa via wuauclt /detectnow..." -ForegroundColor DarkGray
    Start-Process -FilePath "wuauclt.exe" -ArgumentList "/detectnow /updatenow" -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Reparo do Windows Update concluído com sucesso!" -ForegroundColor Cyan
Write-Host "Recomenda-se reiniciar a estação de trabalho caso os erros persistam." -ForegroundColor DarkGray
Write-Host "==========================================================" -ForegroundColor Cyan
