<#
.SYNOPSIS
    Realiza um diagnóstico completo da configuração e conectividade de rede do host.

.DESCRIPTION
    Coleta informações sobre adaptadores de rede físicos/virtuais ativos, endereços IP,
    gateway padrão, servidores DNS e testa a conectividade fim a fim (Gateway, DNS e Internet).

.PARAMETER TestInternet
    Executa testes de ping externo e resolução DNS pública. Padrão: $true.

.EXAMPLE
    .\Get-NetworkDiagnostics.ps1

.EXAMPLE
    .\Get-NetworkDiagnostics.ps1 -TestInternet $false
#>

[CmdletBinding()]
param(
    [switch]$SkipInternetTest
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "         DIAGNÓSTICO DE REDE DO SERVIDOR / HOST          " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Adaptadores Ativos e Configuração IP
Write-Host "[1] Adaptadores de Rede Ativos:" -ForegroundColor Yellow
$Adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }

if (-not $Adapters) {
    Write-Host "  Nenhum adaptador ativo (Status: Up) encontrado!" -ForegroundColor Red
} else {
    foreach ($Adapter in $Adapters) {
        $NetIP = Get-NetIPAddress -InterfaceIndex $Adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $NetRoute = Get-NetRoute -InterfaceIndex $Adapter.InterfaceIndex -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue
        $DnsServers = (Get-DnsClientServerAddress -InterfaceIndex $Adapter.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue).ServerAddresses

        $IPString = if ($NetIP) { ($NetIP.IPAddress) -join ", " } else { "Sem IPv4" }
        $GatewayString = if ($NetRoute) { ($NetRoute.NextHop | Select-Object -Unique) -join ", " } else { "Nenhum" }
        $DnsString = if ($DnsServers) { $DnsServers -join ", " } else { "Nenhum" }

        Write-Host "  Nome da Interface : " -NoNewline; Write-Host $Adapter.Name -ForegroundColor White
        Write-Host "  Descrição         : $($Adapter.InterfaceDescription)" -ForegroundColor DarkGray
        Write-Host "  Endereço MAC      : $($Adapter.MacAddress)" -ForegroundColor DarkGray
        Write-Host "  Velocidade (Link) : $($Adapter.LinkSpeed)" -ForegroundColor DarkGray
        Write-Host "  Endereço IPv4     : " -NoNewline; Write-Host $IPString -ForegroundColor Green
        Write-Host "  Gateway Padrão    : " -NoNewline; Write-Host $GatewayString -ForegroundColor Cyan
        Write-Host "  Servidores DNS    : " -NoNewline; Write-Host $DnsString -ForegroundColor Cyan
        Write-Host "  ----------------------------------------------------" -ForegroundColor DarkGray
    }
}

# 2. Teste de Gateway Padrão
Write-Host ""
Write-Host "[2] Teste de Alcance ao Gateway Padrão:" -ForegroundColor Yellow
$Gateways = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty NextHop -Unique

if ($Gateways) {
    foreach ($Gw in $Gateways) {
        $PingGw = Test-Connection -ComputerName $Gw -Count 2 -Quiet -ErrorAction SilentlyContinue
        if ($PingGw) {
            Write-Host "  Gateway $Gw responde ao Ping: " -NoNewline
            Write-Host "[OK]" -ForegroundColor Green
        } else {
            Write-Host "  Gateway $Gw NÃO responde ao Ping: " -NoNewline
            Write-Host "[FALHA]" -ForegroundColor Red
        }
    }
} else {
    Write-Host "  Nenhum Gateway Padrão configurado." -ForegroundColor Yellow
}

# 3. Teste de Resolução DNS e Conectividade Externa
if (-not $SkipInternetTest) {
    Write-Host ""
    Write-Host "[3] Testes de Conectividade Externa & DNS:" -ForegroundColor Yellow

    # Teste de resolução de nome DNS
    $DomainsToResolve = @("google.com", "microsoft.com")
    foreach ($Domain in $DomainsToResolve) {
        try {
            $Resolved = [System.Net.Dns]::GetHostAddresses($Domain)
            if ($Resolved) {
                Write-Host "  Resolução DNS para $Domain : " -NoNewline
                Write-Host "[OK - $($Resolved[0].IPAddressToString)]" -ForegroundColor Green
            }
        } catch {
            Write-Host "  Resolução DNS para $Domain : " -NoNewline
            Write-Host "[FALHA]" -ForegroundColor Red
        }
    }

    # Teste de alcance a DNS públicos conhecidos (Google & Cloudflare)
    $ExternalHosts = @("8.8.8.8", "1.1.1.1")
    foreach ($ExtHost in $ExternalHosts) {
        $PingExt = Test-Connection -ComputerName $ExtHost -Count 2 -Quiet -ErrorAction SilentlyContinue
        if ($PingExt) {
            Write-Host "  Conectividade IP Externa ($ExtHost) : " -NoNewline
            Write-Host "[OK]" -ForegroundColor Green
        } else {
            Write-Host "  Conectividade IP Externa ($ExtHost) : " -NoNewline
            Write-Host "[FALHA / BLOQUEADO ICMP]" -ForegroundColor Yellow
        }
    }

    # Obter IP Público externo via API rápida
    try {
        $PublicIP = (Invoke-RestMethod -Uri "https://api.ipify.org?format=text" -TimeoutSec 3 -ErrorAction Stop).Trim()
        Write-Host "  IP Público de Saída : " -NoNewline
        Write-Host $PublicIP -ForegroundColor Magenta
    } catch {
        Write-Host "  IP Público de Saída : " -NoNewline
        Write-Host "Indisponível (Sem acesso à internet ou requisição bloqueada)" -ForegroundColor DarkGray
    }
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Diagnóstico concluído." -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
