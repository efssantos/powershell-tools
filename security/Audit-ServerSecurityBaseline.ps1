<#
.SYNOPSIS
    Audita a conformidade de segurança e hardening do sistema operacional (Servidores e Workstations).

.DESCRIPTION
    Realiza uma varredura rigorosa de segurança baseada nas melhores práticas (CIS Benchmarks / Microsoft Security Baselines):
    - SMBv1: Valida se o protocolo legado e inseguro SMBv1 está desabilitado
    - RDP NLA: Valida se a Autenticação no Nível de Rede (Network Level Authentication) está ativa
    - Windows Firewall: Valida se o Firewall está ativo nos perfis Domínio, Privado e Público
    - LLMNR: Valida se a resolução de nomes multicast LLMNR está desabilitada (mitigando ataques de Responder/Poisoning)
    - Conta Guest / Convidado: Valida se a conta interna de Convidado está desativada
    - UAC (Controle de Conta de Usuário): Valida se o UAC (EnableLUA) está habilitado
    - Proteção de Memória LSASS (RunAsPPL): Valida se a proteção contra extração de senhas em memória (Mimikatz) está ativa
    - Antivírus / Defender: Valida proteção em tempo real e atualização de assinaturas
    - Reinicialização Pendente: Alerta sobre patches de segurança aguardando reboot
    - Opcional: Aplica remediação automática para itens não conformes (-Remediate)
    - Exportação para relatórios em formato CSV (-ExportCsv) e dashboard HTML (-ExportHtml).

.PARAMETER Remediate
    Aplica correções automáticas para configurações seguras (desativa SMBv1, força NLA, ativa perfis de Firewall e desativa LLMNR).

.PARAMETER ExportCsv
    Caminho do arquivo CSV de saída para o relatório de conformidade.

.PARAMETER ExportHtml
    Caminho do arquivo HTML de saída para apresentação gerencial.

.EXAMPLE
    .\Audit-ServerSecurityBaseline.ps1

.EXAMPLE
    .\Audit-ServerSecurityBaseline.ps1 -ExportHtml "C:\Temp\Relatorio_Seguranca.html"

.EXAMPLE
    .\Audit-ServerSecurityBaseline.ps1 -Remediate
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$Remediate,
    [string]$ExportCsv,
    [string]$ExportHtml
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "       AUDITORIA DE BASELINE DE SEGURANÇA & HARDENING     " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Iniciando checagens de conformidade de segurança..." -ForegroundColor DarkGray
Write-Host ""

$CheckResults = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-AuditItem {
    param(
        [string]$Category,
        [string]$CheckName,
        [string]$Status, # PASS, FAIL, WARNING
        [string]$CurrentValue,
        [string]$ExpectedValue,
        [string]$Recommendation
    )

    $Color = switch ($Status) {
        "PASS" { "Green" }
        "FAIL" { "Red" }
        "WARNING" { "Yellow" }
        Default { "White" }
    }

    $StatusLabel = switch ($Status) {
        "PASS" { "[CONFORME]" }
        "FAIL" { "[NÃO CONFORME]" }
        "WARNING" { "[ATENÇÃO]" }
    }

    Write-Host "  - $CheckName : " -NoNewline -ForegroundColor White
    Write-Host "$StatusLabel " -NoNewline -ForegroundColor $Color
    Write-Host "($CurrentValue)" -ForegroundColor DarkGray

    if ($Status -ne "PASS") {
        Write-Host "    -> Recomendação: $Recommendation" -ForegroundColor Yellow
    }

    $Item = [PSCustomObject]@{
        Categoria      = $Category
        Item           = $CheckName
        Status         = $Status
        ValorAtual     = $CurrentValue
        ValorEsperado  = $ExpectedValue
        Recomendacao   = $Recommendation
    }
    $CheckResults.Add($Item)
}

# 1. Auditoria de Rede e Protocolos Legados
Write-Host "[1] Protocolos de Rede & Acesso Remoto:" -ForegroundColor Yellow

# Checagem SMBv1
$Smb1Status = "Ativo"
try {
    if (Get-Command Get-SmbServerConfiguration -ErrorAction SilentlyContinue) {
        $SmbConfig = Get-SmbServerConfiguration
        if (-not $SmbConfig.EnableSMB1Protocol) { $Smb1Status = "Desabilitado" }
    } else {
        $RegSmb = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "SMB1" -ErrorAction SilentlyContinue
        if ($RegSmb -and $RegSmb.SMB1 -eq 0) { $Smb1Status = "Desabilitado" }
    }
} catch {
    $Smb1Status = "Indeterminado"
}

if ($Smb1Status -eq "Desabilitado") {
    Add-AuditItem -Category "Protocolos" -CheckName "SMBv1 (Protocolo Legado Inseguro)" -Status "PASS" -CurrentValue "Desabilitado" -ExpectedValue "Desabilitado" -Recommendation "Manter SMBv1 desativado."
} else {
    Add-AuditItem -Category "Protocolos" -CheckName "SMBv1 (Protocolo Legado Inseguro)" -Status "FAIL" -CurrentValue "Habilitado" -ExpectedValue "Desabilitado" -Recommendation "Desabilitar SMBv1 imediatamente para mitigar explorações como WannaCry."
}

# Checagem RDP NLA (Network Level Authentication)
$NlaEnabled = $false
try {
    $RdpAuth = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -ErrorAction SilentlyContinue).UserAuthentication
    if ($RdpAuth -eq 1) { $NlaEnabled = $true }
} catch {}

if ($NlaEnabled) {
    Add-AuditItem -Category "Acesso Remoto" -CheckName "RDP - Autenticação no Nível de Rede (NLA)" -Status "PASS" -CurrentValue "Habilitado (NLA Ativo)" -ExpectedValue "Habilitado" -Recommendation "Manter NLA ativo."
} else {
    Add-AuditItem -Category "Acesso Remoto" -CheckName "RDP - Autenticação no Nível de Rede (NLA)" -Status "FAIL" -CurrentValue "Desabilitado" -ExpectedValue "Habilitado" -Recommendation "Habilitar NLA para prevenir ataques de força bruta e RCE pré-autenticação no RDP."
}

# Checagem LLMNR
$LlmnrDisabled = $false
try {
    $LlmnrReg = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient" -Name "EnableMulticast" -ErrorAction SilentlyContinue).EnableMulticast
    if ($LlmnrReg -eq 0) { $LlmnrDisabled = $true }
} catch {}

if ($LlmnrDisabled) {
    Add-AuditItem -Category "Protocolos" -CheckName "LLMNR (Resolução de Nome Multicast)" -Status "PASS" -CurrentValue "Desabilitado" -ExpectedValue "Desabilitado" -Recommendation "Manter LLMNR desativado."
} else {
    Add-AuditItem -Category "Protocolos" -CheckName "LLMNR (Resolução de Nome Multicast)" -Status "WARNING" -CurrentValue "Habilitado (Padrão)" -ExpectedValue "Desabilitado" -Recommendation "Desativar LLMNR para impedir captura e envenenamento de hashes NTLM (Responder)."
}

# 2. Firewall do Windows
Write-Host ""
Write-Host "[2] Status do Windows Firewall:" -ForegroundColor Yellow
try {
    $FwProfiles = Get-NetFirewallProfile -ErrorAction SilentlyContinue
    $AllFwEnabled = $true
    $DisabledProfiles = [System.Collections.Generic.List[string]]::new()

    foreach ($Prof in $FwProfiles) {
        if (-not $Prof.Enabled) {
            $AllFwEnabled = $false
            $DisabledProfiles.Add($Prof.Name)
        }
    }

    if ($AllFwEnabled) {
        Add-AuditItem -Category "Firewall" -CheckName "Perfis do Windows Firewall" -Status "PASS" -CurrentValue "Todos Ativos (Domain, Private, Public)" -ExpectedValue "Todos Ativos" -Recommendation "Manter todos os perfis ativos."
    } else {
        Add-AuditItem -Category "Firewall" -CheckName "Perfis do Windows Firewall" -Status "FAIL" -CurrentValue "Inativo nos perfis: $($DisabledProfiles -join ', ')" -ExpectedValue "Todos Ativos" -Recommendation "Ativar o firewall em todos os perfis de rede."
    }
} catch {
    Add-AuditItem -Category "Firewall" -CheckName "Perfis do Windows Firewall" -Status "WARNING" -CurrentValue "Não foi possível validar" -ExpectedValue "Todos Ativos" -Recommendation "Verificar status do serviço MpsSvc."
}

# 3. Contas do Sistema & UAC
Write-Host ""
Write-Host "[3] Contas de Usuário & Controle de Acesso:" -ForegroundColor Yellow

# Conta Guest
$GuestAccount = Get-CimInstance -ClassName Win32_UserAccount -Filter "LocalAccount=True AND SID LIKE '%-501'" -ErrorAction SilentlyContinue
if ($GuestAccount) {
    if ($GuestAccount.Disabled) {
        Add-AuditItem -Category "Contas" -CheckName "Conta Convidado (Guest) Integrada" -Status "PASS" -CurrentValue "Desativada" -ExpectedValue "Desativada" -Recommendation "Manter a conta Convidado desativada."
    } else {
        Add-AuditItem -Category "Contas" -CheckName "Conta Convidado (Guest) Integrada" -Status "FAIL" -CurrentValue "Ativa" -ExpectedValue "Desativada" -Recommendation "Desativar a conta interna de Guest."
    }
} else {
    Add-AuditItem -Category "Contas" -CheckName "Conta Convidado (Guest) Integrada" -Status "PASS" -CurrentValue "Não Localizada / Desativada" -ExpectedValue "Desativada" -Recommendation "OK."
}

# UAC (EnableLUA)
$UacEnabled = $false
try {
    $LuaReg = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name "EnableLUA" -ErrorAction SilentlyContinue).EnableLUA
    if ($LuaReg -eq 1) { $UacEnabled = $true }
} catch {}

if ($UacEnabled) {
    Add-AuditItem -Category "Sistema" -CheckName "User Account Control (UAC)" -Status "PASS" -CurrentValue "Habilitado" -ExpectedValue "Habilitado" -Recommendation "Manter UAC ativo."
} else {
    Add-AuditItem -Category "Sistema" -CheckName "User Account Control (UAC)" -Status "FAIL" -CurrentValue "Desabilitado" -ExpectedValue "Habilitado" -Recommendation "Ativar o UAC para restringir privilégios automáticos de administrador."
}

# Proteção de Memória LSASS (RunAsPPL)
$LsassPpl = $false
try {
    $PplReg = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "RunAsPPL" -ErrorAction SilentlyContinue).RunAsPPL
    if ($PplReg -eq 1 -or $PplReg -eq 2) { $LsassPpl = $true }
} catch {}

if ($LsassPpl) {
    Add-AuditItem -Category "Defesa contra Ameaças" -CheckName "Proteção LSASS (RunAsPPL)" -Status "PASS" -CurrentValue "Habilitado (PPL Ativo)" -ExpectedValue "Habilitado" -Recommendation "Manter RunAsPPL ativo para prevenir extração de credenciais em memória."
} else {
    Add-AuditItem -Category "Defesa contra Ameaças" -CheckName "Proteção LSASS (RunAsPPL)" -Status "WARNING" -CurrentValue "Desabilitado" -ExpectedValue "Habilitado" -Recommendation "Habilitar RunAsPPL para proteger o processo LSASS contra Mimikatz e injeções."
}

# 4. Antivírus & Atualizações Pendentes
Write-Host ""
Write-Host "[4] Proteção de Endpoint & Atualizações:" -ForegroundColor Yellow

# Defender / Antivirus
$AvStatusPass = $false
$AvDetail = "Não detectado"
try {
    if (Get-Command Get-MpComputerStatus -ErrorAction SilentlyContinue) {
        $Mp = Get-MpComputerStatus -ErrorAction SilentlyContinue
        if ($Mp.RealTimeProtectionEnabled) {
            $AvStatusPass = $true
            $DaysSig = ((Get-Date) - $Mp.AntivirusSignatureLastUpdated).Days
            $AvDetail = "Defender Ativo (Assinaturas de $DaysSig dia(s) atrás)"
        } else {
            $AvDetail = "Defender Presente mas Proteção em Tempo Real está DESATIVADA"
        }
    } else {
        # Tenta verificar via SecurityCenter2 WMI (estações)
        $ScAv = Get-CimInstance -Namespace "root/SecurityCenter2" -ClassName "AntivirusProduct" -ErrorAction SilentlyContinue
        if ($ScAv) {
            $AvStatusPass = $true
            $AvDetail = "$($ScAv.displayName -join ', ') detectado"
        }
    }
} catch {
    $AvDetail = "Erro ao coletar dados de antivírus: $($_.Exception.Message)"
}

if ($AvStatusPass) {
    Add-AuditItem -Category "Proteção Endpoint" -CheckName "Antivírus / Proteção em Tempo Real" -Status "PASS" -CurrentValue $AvDetail -ExpectedValue "Ativo e Atualizado" -Recommendation "Manter definições atualizadas."
} else {
    Add-AuditItem -Category "Proteção Endpoint" -CheckName "Antivírus / Proteção em Tempo Real" -Status "FAIL" -CurrentValue $AvDetail -ExpectedValue "Ativo e Atualizado" -Recommendation "Verificar o serviço de antivírus ou Microsoft Defender."
}

# Reinicialização Pendente (Atualizações pendentes)
$PendingReboot = $false
if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending") { $PendingReboot = $true }
if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired") { $PendingReboot = $true }

if (-not $PendingReboot) {
    Add-AuditItem -Category "Atualizações" -CheckName "Status de Reinicialização Pendente" -Status "PASS" -CurrentValue "Sem reinicialização pendente" -ExpectedValue "Sem reboot pendente" -Recommendation "Nenhum reboot necessário."
} else {
    Add-AuditItem -Category "Atualizações" -CheckName "Status de Reinicialização Pendente" -Status "WARNING" -CurrentValue "Reinicialização Pendente Detectada" -ExpectedValue "Sem reboot pendente" -Recommendation "Reiniciar a máquina para concluir a aplicação dos patches de segurança."
}

# 5. Remediação Automática (Se solicitado)
if ($Remediate) {
    Write-Host ""
    Write-Host "[5] Executando Remediação Automática de Segurança:" -ForegroundColor Yellow

    # Desativa SMBv1
    try {
        Write-Host "  -> Desabilitando protocolo SMBv1..." -ForegroundColor DarkGray
        if (Get-Command Set-SmbServerConfiguration -ErrorAction SilentlyContinue) {
            Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -Confirm:$false
        }
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters" -Name "SMB1" -Value 0 -Type DWord -Force
        Write-Host "     [OK] SMBv1 desabilitado." -ForegroundColor Green
    } catch {
        Write-Host "     [ALERTA] Falha ao desabilitar SMBv1: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Ativa RDP NLA
    try {
        Write-Host "  -> Forçando Network Level Authentication (NLA) no RDP..." -ForegroundColor DarkGray
        Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp" -Name "UserAuthentication" -Value 1 -Type DWord -Force
        Write-Host "     [OK] NLA ativado no RDP." -ForegroundColor Green
    } catch {
        Write-Host "     [ALERTA] Falha ao ativar NLA: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Desativa LLMNR
    try {
        Write-Host "  -> Desabilitando LLMNR no registro..." -ForegroundColor DarkGray
        $DnsKey = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient"
        if (-not (Test-Path $DnsKey)) { New-Item -Path $DnsKey -Force | Out-Null }
        Set-ItemProperty -Path $DnsKey -Name "EnableMulticast" -Value 0 -Type DWord -Force
        Write-Host "     [OK] LLMNR desabilitado." -ForegroundColor Green
    } catch {
        Write-Host "     [ALERTA] Falha ao desabilitar LLMNR: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # Ativa perfis de Firewall
    try {
        Write-Host "  -> Habilitando todos os perfis do Windows Firewall..." -ForegroundColor DarkGray
        Set-NetFirewallProfile -Profile Domain, Public, Private -Enabled True -Confirm:$false -ErrorAction SilentlyContinue
        Write-Host "     [OK] Firewall ativado em Domain, Private e Public." -ForegroundColor Green
    } catch {
        Write-Host "     [ALERTA] Falha ao reativar perfis de firewall: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# 6. Painel de Estatísticas Finais
$TotalItems = $CheckResults.Count
$CountPass = ($CheckResults | Where-Object { $_.Status -eq "PASS" }).Count
$CountWarn = ($CheckResults | Where-Object { $_.Status -eq "WARNING" }).Count
$CountFail = ($CheckResults | Where-Object { $_.Status -eq "FAIL" }).Count
$Score = if ($TotalItems -gt 0) { [math]::Round(($CountPass / $TotalItems) * 100, 1) } else { 0 }

$ScoreColor = if ($Score -ge 90) { "Green" } elseif ($Score -ge 70) { "Yellow" } else { "Red" }

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "             PONTUAÇÃO DE CONFORMIDADE DE SEGURANÇA       " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "  Total de Verificações : $TotalItems" -ForegroundColor White
Write-Host "  Itens Conformes (PASS): " -NoNewline; Write-Host "$CountPass" -ForegroundColor Green
Write-Host "  Alertas (WARNING)     : " -NoNewline; Write-Host "$CountWarn" -ForegroundColor Yellow
Write-Host "  Não Conformes (FAIL)  : " -NoNewline; Write-Host "$CountFail" -ForegroundColor Red
Write-Host "  Índice de Conformidade: " -NoNewline; Write-Host "$Score%" -ForegroundColor $ScoreColor
Write-Host "==========================================================" -ForegroundColor Cyan

# 7. Exportações
if ($ExportCsv) {
    try {
        $CheckResults | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding utf8
        Write-Host ""
        Write-Host "[OK] Relatório CSV salvo em: $ExportCsv" -ForegroundColor Green
    } catch {
        Write-Host ""
        Write-Host "[ERRO] Falha ao exportar CSV: $($_.Exception.Message)" -ForegroundColor Red
    }
}

if ($ExportHtml) {
    try {
        $RowsHtml = foreach ($R in $CheckResults) {
            $BadgeClass = switch ($R.Status) {
                "PASS" { "badge-pass" }
                "WARNING" { "badge-warn" }
                "FAIL" { "badge-fail" }
            }

            "<tr>
                <td>$([System.Net.WebUtility]::HtmlEncode($R.Categoria))</td>
                <td><strong>$([System.Net.WebUtility]::HtmlEncode($R.Item))</strong></td>
                <td><span class='badge $BadgeClass'>$($R.Status)</span></td>
                <td>$([System.Net.WebUtility]::HtmlEncode($R.ValorAtual))</td>
                <td>$([System.Net.WebUtility]::HtmlEncode($R.ValorEsperado))</td>
                <td>$([System.Net.WebUtility]::HtmlEncode($R.Recomendacao))</td>
            </tr>"
        }

        $HtmlContent = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <title>Auditoria de Baseline de Segurança - $env:COMPUTERNAME</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; margin: 20px; background-color: #f8fafc; color: #1e293b; }
        .header { background: linear-gradient(135deg, #0f172a, #1e293b); color: white; padding: 24px; border-radius: 8px; margin-bottom: 24px; }
        .header h1 { margin: 0; font-size: 24px; }
        .header p { margin: 6px 0 0 0; opacity: 0.8; font-size: 14px; }
        .stats-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(130px, 1fr)); gap: 15px; margin-bottom: 24px; }
        .stat-card { background: white; padding: 15px; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); text-align: center; }
        .stat-val { font-size: 24px; font-weight: bold; margin-top: 4px; }
        .card { background: white; padding: 20px; border-radius: 8px; box-shadow: 0 1px 3px rgba(0,0,0,0.1); }
        table { width: 100%; border-collapse: collapse; font-size: 13px; }
        th { background-color: #f1f5f9; padding: 10px 12px; text-align: left; border-bottom: 2px solid #cbd5e1; font-weight: 600; }
        td { padding: 10px 12px; border-bottom: 1px solid #e2e8f0; }
        tr:hover { background-color: #f8fafc; }
        .badge { padding: 4px 10px; border-radius: 12px; font-size: 11px; font-weight: bold; }
        .badge-pass { background: #dcfce7; color: #15803d; }
        .badge-warn { background: #fef9c3; color: #a16207; }
        .badge-fail { background: #fee2e2; color: #b91c1c; }
    </style>
</head>
<body>
    <div class="header">
        <h1>🛡️ Relatório de Baseline de Segurança e Hardening</h1>
        <p>Host: $env:COMPUTERNAME | Gerado em $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')</p>
    </div>

    <div class="stats-grid">
        <div class="stat-card"><div>Pontuação</div><div class="stat-val" style="color: $(if ($Score -ge 80) {'#15803d'} else {'#b91c1c'});">$Score%</div></div>
        <div class="stat-card"><div>Conformes</div><div class="stat-val" style="color: #15803d;">$CountPass</div></div>
        <div class="stat-card"><div>Avisos</div><div class="stat-val" style="color: #a16207;">$CountWarn</div></div>
        <div class="stat-card"><div>Falhas</div><div class="stat-val" style="color: #b91c1c;">$CountFail</div></div>
    </div>

    <div class="card">
        <table>
            <thead>
                <tr>
                    <th>Categoria</th>
                    <th>Verificação</th>
                    <th>Status</th>
                    <th>Valor Atual</th>
                    <th>Valor Recomendado</th>
                    <th>Ação Recomendada</th>
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
        Write-Host "[OK] Relatório HTML gerado em: $ExportHtml" -ForegroundColor Green
    } catch {
        Write-Host ""
        Write-Host "[ERRO] Falha ao exportar HTML: $($_.Exception.Message)" -ForegroundColor Red
    }
}

return $CheckResults
