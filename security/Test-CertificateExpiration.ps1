<#
.SYNOPSIS
    Verifica a validade e a expiração de certificados digitais SSL/TLS locais, no IIS e em endpoints remotos.

.DESCRIPTION
    Script indispensável para prevenção de indisponibilidades por expiração de certificados SSL/TLS:
    - Inspeciona os repositórios locais do Windows (Cert:\LocalMachine\My e WebHosting)
    - Inspeciona certificados vinculados a sites do IIS (quando a role/módulo WebAdministration estiver presente)
    - Inspeciona endpoints remotos via handshake TLS/SSL em portas como 443, 636 (LDAPS), 8443, etc.
    - Classifica a integridade por faixas: OK (Verde), Alerta (Amarelo, <= 30 dias), Crítico (Vermelho, <= 15 dias) e Expirado
    - Gera relatórios em formato CSV (-ExportCsv) e painel HTML (-ExportHtml)
    - Retorna objetos no pipeline para fácil integração com automações e tarefas agendadas.

.PARAMETER WarningDays
    Dias restantes até a expiração para emitir status de Alerta (Padrão: 30 dias).

.PARAMETER CriticalDays
    Dias restantes até a expiração para emitir status Crítico (Padrão: 15 dias).

.PARAMETER Endpoints
    Lista de URLs ou endpoints remotos no formato "host:porta" ou "https://host" para validação direta.

.PARAMETER CheckIIS
    Inspeciona especificamente os certificados vinculados aos sites do IIS local.

.PARAMETER ExportCsv
    Caminho do arquivo CSV para exportação dos resultados.

.PARAMETER ExportHtml
    Caminho do arquivo HTML para geração de painel visual.

.EXAMPLE
    .\Test-CertificateExpiration.ps1

.EXAMPLE
    .\Test-CertificateExpiration.ps1 -WarningDays 45 -CriticalDays 20

.EXAMPLE
    .\Test-CertificateExpiration.ps1 -Endpoints "https://portal.empresa.com.br", "srv-ad01.empresa.local:636" -ExportHtml "C:\Temp\Certificados.html"
#>

[CmdletBinding()]
param(
    [int]$WarningDays = 30,
    [int]$CriticalDays = 15,
    [string[]]$Endpoints = @(),
    [switch]$CheckIIS,
    [string]$ExportCsv,
    [string]$ExportHtml
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "     AUDITORIA DE VALIDADE DE CERTIFICADOS DIGITAIS       " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Verificando repositórios locais e endpoints..." -ForegroundColor DarkGray
Write-Host ""

$CertificateResults = [System.Collections.Generic.List[PSCustomObject]]::new()
$Today = Get-Date

function Get-CertificateStatus {
    param(
        [datetime]$ExpirationDate,
        [int]$WarnDays,
        [int]$CritDays
    )

    $DaysLeft = [math]::Floor(($ExpirationDate - (Get-Date)).TotalDays)

    if ($DaysLeft -lt 0) {
        return @{ Status = "EXPIRADO"; Color = "Red"; DaysLeft = $DaysLeft }
    } elseif ($DaysLeft -le $CritDays) {
        return @{ Status = "CRÍTICO"; Color = "Red"; DaysLeft = $DaysLeft }
    } elseif ($DaysLeft -le $WarnDays) {
        return @{ Status = "ALERTA"; Color = "Yellow"; DaysLeft = $DaysLeft }
    } else {
        return @{ Status = "OK"; Color = "Green"; DaysLeft = $DaysLeft }
    }
}

# 1. Auditoria dos Repositórios Locais (LocalMachine\My e WebHosting)
Write-Host "[1] Repositórios Locais do Servidor / Host:" -ForegroundColor Yellow

$StorePaths = @(
    "Cert:\LocalMachine\My",
    "Cert:\LocalMachine\WebHosting"
)

foreach ($StorePath in $StorePaths) {
    if (Test-Path $StorePath) {
        $StoreName = Split-Path $StorePath -Leaf
        $Certs = Get-ChildItem -Path $StorePath -ErrorAction SilentlyContinue | Where-Object { $_ -is [System.Security.Cryptography.X509Certificates.X509Certificate2] }

        Write-Host "  -> Repositório Local: $StoreName ($($Certs.Count) certificado(s) encontrado(s))" -ForegroundColor White

        foreach ($Cert in $Certs) {
            $Subject = if ($Cert.FriendlyName) { "$($Cert.FriendlyName) ($($Cert.Subject))" } else { $Cert.Subject }
            $StatusInfo = Get-CertificateStatus -ExpirationDate $Cert.NotAfter -WarnDays $WarningDays -CritDays $CriticalDays

            $ResultItem = [PSCustomObject]@{
                Origem        = "Repositório Local ($StoreName)"
                NomeAmigavel  = if ($Cert.FriendlyName) { $Cert.FriendlyName } else { "N/A" }
                Assunto       = $Cert.Subject
                Emissor       = $Cert.Issuer
                ValidoDe      = $Cert.NotBefore.ToString("yyyy-MM-dd")
                ExpiraEm      = $Cert.NotAfter.ToString("yyyy-MM-dd")
                DiasRestantes = $StatusInfo.DaysLeft
                Thumbprint    = $Cert.Thumbprint
                Status        = $StatusInfo.Status
            }
            $CertificateResults.Add($ResultItem)

            Write-Host "     - $($Cert.Thumbprint.Substring(0, 10))... | " -NoNewline -ForegroundColor DarkGray
            Write-Host "[$($StatusInfo.Status)] " -NoNewline -ForegroundColor $StatusInfo.Color
            Write-Host "Expira em $($StatusInfo.DaysLeft) dia(s) - $($Cert.Subject)" -ForegroundColor White
        }
    }
}

# 2. Auditoria do IIS (caso solicitado ou se o IIS estiver instalado)
if ($CheckIIS -or (Get-Service -Name W3SVC -ErrorAction SilentlyContinue)) {
    Write-Host ""
    Write-Host "[2] Certificados Vinculados aos Sites do IIS:" -ForegroundColor Yellow
    try {
        if (-not (Get-Module -Name WebAdministration -ListAvailable)) {
            Write-Host "  Módulo WebAdministration não disponível no host." -ForegroundColor DarkGray
        } else {
            Import-Module WebAdministration -ErrorAction SilentlyContinue
            $Bindings = Get-WebBinding -Protocol "https" -ErrorAction SilentlyContinue

            if ($Bindings) {
                foreach ($Binding in $Bindings) {
                    $SiteName = $Binding.ItemXPath.Split("'")[1]
                    $Thumbprint = $Binding.certificateHash
                    $Cert = Get-Item "Cert:\LocalMachine\*\$Thumbprint" -ErrorAction SilentlyContinue

                    if ($Cert) {
                        $StatusInfo = Get-CertificateStatus -ExpirationDate $Cert.NotAfter -WarnDays $WarningDays -CritDays $CriticalDays
                        $ResultItem = [PSCustomObject]@{
                            Origem        = "IIS Site: $SiteName ($($Binding.bindingInformation))"
                            NomeAmigavel  = if ($Cert.FriendlyName) { $Cert.FriendlyName } else { "N/A" }
                            Assunto       = $Cert.Subject
                            Emissor       = $Cert.Issuer
                            ValidoDe      = $Cert.NotBefore.ToString("yyyy-MM-dd")
                            ExpiraEm      = $Cert.NotAfter.ToString("yyyy-MM-dd")
                            DiasRestantes = $StatusInfo.DaysLeft
                            Thumbprint    = $Cert.Thumbprint
                            Status        = $StatusInfo.Status
                        }
                        $CertificateResults.Add($ResultItem)

                        Write-Host "     - Site: $SiteName ($($Binding.bindingInformation)) | " -NoNewline -ForegroundColor White
                        Write-Host "[$($StatusInfo.Status)] " -NoNewline -ForegroundColor $StatusInfo.Color
                        Write-Host "Expira em $($StatusInfo.DaysLeft) dias" -ForegroundColor White
                    }
                }
            } else {
                Write-Host "  Nenhum binding HTTPS configurado no IIS local." -ForegroundColor DarkGray
            }
        }
    } catch {
        Write-Host "  [ALERTA] Não foi possível consultar o IIS: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# 3. Auditoria de Endpoints Remotos (Handshake TLS via Socket)
if ($Endpoints.Count -gt 0) {
    Write-Host ""
    Write-Host "[3] Validação de Endpoints Remotos (TLS Handshake):" -ForegroundColor Yellow

    foreach ($Endpoint in $Endpoints) {
        $CleanHost = $Endpoint.Trim()
        $Port = 443

        if ($CleanHost -match "^https?://([^/:]+)(?::(\d+))?") {
            $TargetHost = $Matches[1]
            if ($Matches[2]) { $Port = [int]$Matches[2] }
        } elseif ($CleanHost -match "^([^:]+):(\d+)$") {
            $TargetHost = $Matches[1]
            $Port = [int]$Matches[2]
        } else {
            $TargetHost = $CleanHost
        }

        Write-Host "  -> Conectando em $($TargetHost):$Port..." -ForegroundColor DarkGray

        try {
            $TcpClient = [System.Net.Sockets.TcpClient]::new()
            $AsyncResult = $TcpClient.BeginConnect($TargetHost, $Port, $null, $null)
            $Success = $AsyncResult.AsyncWaitHandle.WaitOne(3000, $false)

            if (-not $Success -or -not $TcpClient.Connected) {
                Write-Host "     [FALHA] Não foi possível conectar a $TargetHost na porta $Port." -ForegroundColor Red
                $TcpClient.Close()
                continue
            }

            $SslStream = [System.Net.Security.SslStream]::new(
                $TcpClient.GetStream(),
                $false,
                ({ $true } -as [System.Net.Security.RemoteCertificateValidationCallback])
            )

            $SslStream.AuthenticateAsClient($TargetHost)
            $RemoteCert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($SslStream.RemoteCertificate)

            if ($RemoteCert) {
                $StatusInfo = Get-CertificateStatus -ExpirationDate $RemoteCert.NotAfter -WarnDays $WarningDays -CritDays $CriticalDays

                $ResultItem = [PSCustomObject]@{
                    Origem        = "Remoto: $($TargetHost):$Port"
                    NomeAmigavel  = "N/A"
                    Assunto       = $RemoteCert.Subject
                    Emissor       = $RemoteCert.Issuer
                    ValidoDe      = $RemoteCert.NotBefore.ToString("yyyy-MM-dd")
                    ExpiraEm      = $RemoteCert.NotAfter.ToString("yyyy-MM-dd")
                    DiasRestantes = $StatusInfo.DaysLeft
                    Thumbprint    = $RemoteCert.Thumbprint
                    Status        = $StatusInfo.Status
                }
                $CertificateResults.Add($ResultItem)

                Write-Host "     [$($StatusInfo.Status)] " -NoNewline -ForegroundColor $StatusInfo.Color
                Write-Host "$TargetHost | Expira em $($StatusInfo.DaysLeft) dia(s) ($($RemoteCert.NotAfter.ToString('yyyy-MM-dd')))" -ForegroundColor White
            }

            $SslStream.Close()
            $TcpClient.Close()
        } catch {
            Write-Host "     [ERRO TLS] Falha ao inspecionar $($TargetHost):$Port - $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}

# 4. Resumo & Painel Estatístico
Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "             RESUMO DA AUDITORIA DE CERTIFICADOS          " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$TotalCerts = $CertificateResults.Count
$CountOk = ($CertificateResults | Where-Object { $_.Status -eq "OK" }).Count
$CountAlert = ($CertificateResults | Where-Object { $_.Status -eq "ALERTA" }).Count
$CountCritical = ($CertificateResults | Where-Object { $_.Status -eq "CRÍTICO" }).Count
$CountExpired = ($CertificateResults | Where-Object { $_.Status -eq "EXPIRADO" }).Count

Write-Host "  Total Auditados : $TotalCerts certificado(s)" -ForegroundColor White
Write-Host "  Em Dia (OK)     : " -NoNewline; Write-Host "$CountOk" -ForegroundColor Green
Write-Host "  Alerta (<= $WarningDays d): " -NoNewline; Write-Host "$CountAlert" -ForegroundColor Yellow
Write-Host "  Crítico (<= $CriticalDays d): " -NoNewline; Write-Host "$CountCritical" -ForegroundColor Red
Write-Host "  Expirados       : " -NoNewline; Write-Host "$CountExpired" -ForegroundColor Red
Write-Host "==========================================================" -ForegroundColor Cyan

# 5. Exportação de Dados (CSV e HTML)
if ($ExportCsv -and $CertificateResults.Count -gt 0) {
    try {
        $CertificateResults | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding utf8
        Write-Host ""
        Write-Host "[OK] Relatório CSV salvo em: $ExportCsv" -ForegroundColor Green
    } catch {
        Write-Host ""
        Write-Host "[ERRO] Falha ao exportar CSV: $($_.Exception.Message)" -ForegroundColor Red
    }
}

if ($ExportHtml -and $CertificateResults.Count -gt 0) {
    try {
        $RowsHtml = foreach ($C in $CertificateResults) {
            $BadgeClass = switch ($C.Status) {
                "OK" { "badge-ok" }
                "ALERTA" { "badge-alert" }
                "CRÍTICO" { "badge-crit" }
                "EXPIRADO" { "badge-expired" }
                Default { "badge-ok" }
            }

            "<tr>
                <td>$([System.Net.WebUtility]::HtmlEncode($C.Origem))</td>
                <td>$([System.Net.WebUtility]::HtmlEncode($C.Assunto))</td>
                <td>$([System.Net.WebUtility]::HtmlEncode($C.Emissor))</td>
                <td>$($C.ExpiraEm)</td>
                <td><strong>$($C.DiasRestantes) dias</strong></td>
                <td><span class='badge $BadgeClass'>$($C.Status)</span></td>
            </tr>"
        }

        $HtmlContent = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <title>Auditoria de Certificados SSL/TLS</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; margin: 20px; background-color: #f8fafc; color: #1e293b; }
        .header { background: linear-gradient(135deg, #4f46e5, #3730a3); color: white; padding: 24px; border-radius: 8px; margin-bottom: 24px; }
        .header h1 { margin: 0; font-size: 24px; }
        .header p { margin: 6px 0 0 0; opacity: 0.9; font-size: 14px; }
        .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(140px, 1fr)); gap: 15px; margin-bottom: 24px; }
        .stat-card { background: white; padding: 15px; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); text-align: center; }
        .stat-val { font-size: 24px; font-weight: bold; margin-top: 4px; }
        .card { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        table { width: 100%; border-collapse: collapse; font-size: 13px; }
        th { background-color: #f1f5f9; padding: 10px 12px; text-align: left; border-bottom: 2px solid #cbd5e1; font-weight: 600; }
        td { padding: 9px 12px; border-bottom: 1px solid #e2e8f0; }
        tr:hover { background-color: #f8fafc; }
        .badge { padding: 4px 10px; border-radius: 12px; font-size: 11px; font-weight: bold; }
        .badge-ok { background: #dcfce7; color: #15803d; }
        .badge-alert { background: #fef9c3; color: #a16207; }
        .badge-crit { background: #fee2e2; color: #b91c1c; }
        .badge-expired { background: #7f1d1d; color: white; }
    </style>
</head>
<body>
    <div class="header">
        <h1>🔐 Auditoria de Certificados Digitais SSL/TLS</h1>
        <p>Gerado em $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')</p>
    </div>

    <div class="stats-grid">
        <div class="stat-card"><div>Total</div><div class="stat-val">$TotalCerts</div></div>
        <div class="stat-card"><div>Válidos</div><div class="stat-val" style="color: #15803d;">$CountOk</div></div>
        <div class="stat-card"><div>Alerta</div><div class="stat-val" style="color: #a16207;">$CountAlert</div></div>
        <div class="stat-card"><div>Crítico</div><div class="stat-val" style="color: #b91c1c;">$CountCritical</div></div>
        <div class="stat-card"><div>Expirados</div><div class="stat-val" style="color: #7f1d1d;">$CountExpired</div></div>
    </div>

    <div class="card">
        <table>
            <thead>
                <tr>
                    <th>Origem</th>
                    <th>Assunto (Subject)</th>
                    <th>Emissor (Issuer)</th>
                    <th>Data Expiração</th>
                    <th>Dias Restantes</th>
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
        Write-Host "[OK] Relatório HTML salvo em: $ExportHtml" -ForegroundColor Green
    } catch {
        Write-Host ""
        Write-Host "[ERRO] Falha ao exportar HTML: $($_.Exception.Message)" -ForegroundColor Red
    }
}

return $CertificateResults
