<#
.SYNOPSIS
    Restaura e redefine completamente a pilha de rede, DNS e adaptadores no Windows.

.DESCRIPTION
    Script indispensável para resolução rápida de incidentes de conectividade em estações de trabalho e servidores:
    - Libera e renova concessões DHCP (ipconfig /release & /renew)
    - Limpa e registra novamente o cache do cliente DNS (ipconfig /flushdns & /registerdns)
    - Limpa as tabelas de cache NetBIOS e ARP (Clear-NetNeighbor / arp -d)
    - Redefine o catálogo do Winsock para o estado padrão (netsh winsock reset)
    - Redefine as configurações da pilha TCP/IP IPv4 e IPv6 (netsh int ip reset)
    - Redefine configurações de Proxy WinHTTP que possam estar travadas (netsh winhttp reset proxy)
    - Opcionalmente reinicia os adaptadores de rede físicos ativos (-RestartAdapters)
    - Executa um teste final de conectividade (Gateway, DNS e Internet)
    - Permite agendar reinicialização do sistema se desejado (-RestartComputer)

.PARAMETER RestartAdapters
    Reinicia os adaptadores de rede ativos para aplicar as novas configurações sem reiniciar a máquina inteira.

.PARAMETER RestartComputer
    Solicita ou força a reinicialização da máquina após a conclusão dos reparos.

.PARAMETER Force
    Executa sem solicitar confirmação manual.

.EXAMPLE
    .\Reset-NetworkStack.ps1

.EXAMPLE
    .\Reset-NetworkStack.ps1 -RestartAdapters

.EXAMPLE
    .\Reset-NetworkStack.ps1 -RestartAdapters -RestartComputer
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$RestartAdapters,
    [switch]$RestartComputer,
    [switch]$Force
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "       RESTAURAÇÃO & REDEFINIÇÃO DA PILHA DE REDE         " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Iniciando processo de reparo e saneamento de rede..." -ForegroundColor DarkGray
Write-Host ""

# Verificação de privilégios de Administrador
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Host "[ERRO] Este script requer privilégios elevados (Executar como Administrador)." -ForegroundColor Red
    return
}

# 1. Liberação e Renovação de DHCP
Write-Host "[1] Liberando e renovando concessões DHCP..." -ForegroundColor Yellow
try {
    Write-Host "  -> Executando ipconfig /release..." -ForegroundColor DarkGray
    $null = ipconfig.exe /release 2>&1
    Write-Host "  -> Executando ipconfig /renew..." -ForegroundColor DarkGray
    $null = ipconfig.exe /renew 2>&1
    Write-Host "  [OK] Concessões DHCP renovadas com sucesso." -ForegroundColor Green
} catch {
    Write-Host "  [ALERTA] Falha ao renovar DHCP: $($_.Exception.Message)" -ForegroundColor Yellow
}

# 2. Limpeza de Caches DNS, NetBIOS e ARP
Write-Host ""
Write-Host "[2] Limpando caches de resolução (DNS, NetBIOS, ARP)..." -ForegroundColor Yellow

try {
    Write-Host "  -> Limpando cache do resolvedor DNS (/flushdns)..." -ForegroundColor DarkGray
    $null = ipconfig.exe /flushdns 2>&1
    Write-Host "  -> Registrando novamente nomes no DNS (/registerdns)..." -ForegroundColor DarkGray
    $null = ipconfig.exe /registerdns 2>&1
    Write-Host "  [OK] Cache DNS limpo e registro solicitado." -ForegroundColor Green
} catch {
    Write-Host "  [ALERTA] Erro ao limpar cache DNS: $($_.Exception.Message)" -ForegroundColor Yellow
}

try {
    Write-Host "  -> Limpando tabela ARP do sistema..." -ForegroundColor DarkGray
    if (Get-Command Clear-NetNeighbor -ErrorAction SilentlyContinue) {
        Clear-NetNeighbor -Confirm:$false -ErrorAction SilentlyContinue
    } else {
        $null = arp.exe -d * 2>&1
    }
    Write-Host "  [OK] Tabela ARP limpa com sucesso." -ForegroundColor Green
} catch {
    Write-Host "  [ALERTA] Falha ao limpar tabela ARP." -ForegroundColor Yellow
}

try {
    Write-Host "  -> Purgando tabela de nomes NetBIOS (nbtstat)..." -ForegroundColor DarkGray
    $null = nbtstat.exe -R 2>&1
    $null = nbtstat.exe -RR 2>&1
    Write-Host "  [OK] Cache NetBIOS purgado." -ForegroundColor Green
} catch {
    Write-Host "  [ALERTA] Não foi possível executar o nbtstat." -ForegroundColor DarkGray
}

# 3. Redefinição de Proxy WinHTTP
Write-Host ""
Write-Host "[3] Redefinindo configurações de Proxy WinHTTP..." -ForegroundColor Yellow
try {
    $ProxyResult = netsh.exe winhttp reset proxy 2>&1
    Write-Host "  [OK] Configuração de Proxy WinHTTP redefinida para conexão direta." -ForegroundColor Green
} catch {
    Write-Host "  [ALERTA] Erro ao redefinir proxy WinHTTP: $($_.Exception.Message)" -ForegroundColor Yellow
}

# 4. Redefinição do Catálogo Winsock e Pilha TCP/IP
Write-Host ""
Write-Host "[4] Redefinindo catálogo Winsock e pilha TCP/IP..." -ForegroundColor Yellow
$LogPath = Join-Path $env:TEMP "tcp_reset_log.txt"

try {
    Write-Host "  -> Resetando catálogo Winsock..." -ForegroundColor DarkGray
    $null = netsh.exe winsock reset 2>&1

    Write-Host "  -> Resetando configurações IPv4 e IPv6..." -ForegroundColor DarkGray
    $null = netsh.exe int ip reset $LogPath 2>&1
    $null = netsh.exe int ipv6 reset 2>&1

    Write-Host "  [OK] Winsock e TCP/IP restaurados aos padrões de fábrica." -ForegroundColor Green
} catch {
    Write-Host "  [ERRO] Falha ao redefinir TCP/IP: $($_.Exception.Message)" -ForegroundColor Red
}

# 5. Reinicialização de Adaptadores (Opcional)
if ($RestartAdapters) {
    Write-Host ""
    Write-Host "[5] Reiniciando adaptadores de rede ativos..." -ForegroundColor Yellow
    $ActiveAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" -and $_.Virtual -eq $false }

    if (-not $ActiveAdapters) {
        $ActiveAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Up" }
    }

    foreach ($Adapter in $ActiveAdapters) {
        Write-Host "  -> Reiniciando adaptador '$($Adapter.Name)' ($($Adapter.InterfaceDescription))..." -ForegroundColor DarkGray
        try {
            Restart-NetAdapter -Name $Adapter.Name -Confirm:$false -ErrorAction Stop
            Write-Host "     [OK] Adaptador '$($Adapter.Name)' reiniciado." -ForegroundColor Green
        } catch {
            Write-Host "     [ALERTA] Não foi possível reiniciar '$($Adapter.Name)': $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    Write-Host "  Aguardando 3 segundos para estabilização dos links..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 3
}

# 6. Teste de Conectividade Fim a Fim
Write-Host ""
Write-Host "[6] Validando conectividade após reparo:" -ForegroundColor Yellow

# Teste Gateway
$DefaultGateways = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty NextHop -Unique
if ($DefaultGateways) {
    foreach ($Gw in $DefaultGateways) {
        if ($Gw -and $Gw -ne "0.0.0.0") {
            $PingGw = Test-Connection -ComputerName $Gw -Count 1 -Quiet -ErrorAction SilentlyContinue
            if ($PingGw) {
                Write-Host "  Gateway Padrão ($Gw) : " -NoNewline; Write-Host "[ALCANÇÁVEL]" -ForegroundColor Green
            } else {
                Write-Host "  Gateway Padrão ($Gw) : " -NoNewline; Write-Host "[INACESSÍVEL / SEM RESPOSTA]" -ForegroundColor Yellow
            }
        }
    }
} else {
    Write-Host "  Gateway Padrão : " -NoNewline; Write-Host "[NENHUM DETECTADO]" -ForegroundColor Yellow
}

# Teste DNS
try {
    $DnsTest = [System.Net.Dns]::GetHostAddresses("dns.google")
    if ($DnsTest) {
        Write-Host "  Resolução de DNS Externo : " -NoNewline; Write-Host "[SUCESSO (dns.google OK)]" -ForegroundColor Green
    } else {
        Write-Host "  Resolução de DNS Externo : " -NoNewline; Write-Host "[FALHA]" -ForegroundColor Red
    }
} catch {
    Write-Host "  Resolução de DNS Externo : " -NoNewline; Write-Host "[FALHA]" -ForegroundColor Red
}

# Teste Internet (Porta 443 TCP)
try {
    $TcpClient = [System.Net.Sockets.TcpClient]::new()
    $AsyncConnect = $TcpClient.BeginConnect("1.1.1.1", 443, $null, $null)
    $Success = $AsyncConnect.AsyncWaitHandle.WaitOne(2000, $false)
    if ($Success -and $TcpClient.Connected) {
        $TcpClient.EndConnect($AsyncConnect)
        Write-Host "  Acesso à Internet (TCP 443): " -NoNewline; Write-Host "[CONECTADO]" -ForegroundColor Green
    } else {
        Write-Host "  Acesso à Internet (TCP 443): " -NoNewline; Write-Host "[SEM SAÍDA EXTERNA]" -ForegroundColor Red
    }
    $TcpClient.Close()
} catch {
    Write-Host "  Acesso à Internet (TCP 443): " -NoNewline; Write-Host "[SEM SAÍDA EXTERNA]" -ForegroundColor Red
}

# 7. Conclusão & Reinicialização
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Procedimento de redefinição de rede concluído!          " -ForegroundColor Green
Write-Host "  Nota: Para que algumas alterações de Winsock/TCP entrem " -ForegroundColor DarkGray
Write-Host "  em vigor total, recomenda-se reiniciar o computador.    " -ForegroundColor DarkGray
Write-Host "==========================================================" -ForegroundColor Cyan

if ($RestartComputer) {
    if ($Force -or $PSCmdlet.ShouldProcess($env:COMPUTERNAME, "Reiniciar Computador")) {
        Write-Host "Reiniciando o sistema em 10 segundos... Pressione Ctrl+C para abortar." -ForegroundColor Red
        shutdown.exe /r /t 10 /c "Reinicializacao para conclusao do reparo de rede."
    }
}
