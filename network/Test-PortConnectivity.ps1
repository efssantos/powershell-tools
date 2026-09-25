<#
.SYNOPSIS
    Testa a conectividade de portas TCP em um ou mais servidores/endereços IP.

.DESCRIPTION
    Script para diagnóstico rápido de conectividade de rede e regras de firewall.
    Testa múltiplos destinos e portas TCP utilizando sockets .NET para alta performance e precisão.

.PARAMETER Destination
    Nome do host, FQDN ou endereço IP do alvo (aceita múltiplos).

.PARAMETER Ports
    Porta(s) TCP para testar. Padrão: 80, 443, 3389, 445, 53, 22.

.PARAMETER TimeoutMs
    Tempo limite de conexão em milissegundos. Padrão: 2000ms.

.EXAMPLE
    .\Test-PortConnectivity.ps1 -Destination "192.168.1.10" -Ports 3389, 445

.EXAMPLE
    .\Test-PortConnectivity.ps1 -Destination "google.com", "microsoft.com" -Ports 80, 443
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0, ValueFromPipeline = $true)]
    [string[]]$Destination = @("127.0.0.1"),

    [Parameter(Position = 1)]
    [int[]]$Ports = @(80, 443, 3389, 445, 53, 22),

    [int]$TimeoutMs = 2000
)

# Common port service map for quick reference
$CommonServices = @{
    21   = "FTP"
    22   = "SSH"
    25   = "SMTP"
    53   = "DNS"
    80   = "HTTP"
    88   = "Kerberos"
    135  = "RPC"
    139  = "NetBIOS"
    389  = "LDAP"
    443  = "HTTPS"
    445  = "SMB"
    636  = "LDAPS"
    1433 = "MS-SQL"
    3306 = "MySQL"
    3389 = "RDP"
    5985 = "WinRM-HTTP"
    5986 = "WinRM-HTTPS"
    8080 = "HTTP-Alt"
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "   TESTE DE CONECTIVIDADE DE REDE & PORTAS TCP            " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Iniciando testes... (Timeout por porta: ${TimeoutMs}ms)" -ForegroundColor DarkGray
Write-Host ""

$Results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($Target in $Destination) {
    Write-Host "Verificando destino: " -NoNewline
    Write-Host $Target -ForegroundColor Yellow

    # Resolver DNS
    $ResolvedIP = $null
    try {
        $DnsAddresses = [System.Net.Dns]::GetHostAddresses($Target)
        $Ipv4List = $DnsAddresses | Where-Object { $_.AddressFamily -eq 'InterNetwork' }
        if ($Ipv4List) {
            $ResolvedIP = $Ipv4List[0].IPAddressToString
        } else {
            $ResolvedIP = $DnsAddresses[0].IPAddressToString
        }
        Write-Host "  -> IP Resolvido: $ResolvedIP" -ForegroundColor DarkCyan
    }
    catch {
        Write-Host "  -> Falha na resolução de DNS para '$Target'" -ForegroundColor Red
        $ResolvedIP = "Falha DNS"
    }

    foreach ($Port in $Ports) {
        $ServiceName = if ($CommonServices.ContainsKey($Port)) { $CommonServices[$Port] } else { "Personalizado" }
        $Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $IsOpen = $false
        $ErrorMsg = ""

        if ($ResolvedIP -ne "Falha DNS") {
            $TcpClient = [System.Net.Sockets.TcpClient]::new()
            try {
                $ConnectTask = $TcpClient.ConnectAsync($ResolvedIP, $Port)
                $Completed = $ConnectTask.Wait($TimeoutMs)

                if ($Completed -and $TcpClient.Connected) {
                    $IsOpen = $true
                } else {
                    $ErrorMsg = "Tempo limite excedido"
                }
            }
            catch {
                $ErrorMsg = $_.Exception.InnerException.Message
                if (-not $ErrorMsg) { $ErrorMsg = $_.Exception.Message }
            }
            finally {
                $TcpClient.Close()
                $TcpClient.Dispose()
            }
        } else {
            $ErrorMsg = "DNS não resolvido"
        }

        $Stopwatch.Stop()
        $Latency = [math]::Round($Stopwatch.Elapsed.TotalMilliseconds, 2)

        $StatusText = if ($IsOpen) { "ABERTA" } else { "FECHADA" }
        $Color = if ($IsOpen) { "Green" } else { "Red" }

        Write-Host "  Porta $Port ($ServiceName): " -NoNewline
        Write-Host "[$StatusText]" -ForegroundColor $Color -NoNewline
        Write-Host " (${Latency}ms) $ErrorMsg" -ForegroundColor DarkGray

        $Results.Add([PSCustomObject]@{
            Destino     = $Target
            IP          = $ResolvedIP
            Porta       = $Port
            Servico     = $ServiceName
            Status      = $StatusText
            Latencia_ms = $Latency
            Detalhes    = $ErrorMsg
        })
    }
    Write-Host ""
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Resumo concluído. Retornando objetos para pipeline se necessário." -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

return $Results
