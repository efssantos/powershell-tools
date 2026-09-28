<#
.SYNOPSIS
    Localiza contas de usuários e computadores inativos ou obsoletos no Active Directory.

.DESCRIPTION
    Script indispensável para higienização e governança do Active Directory:
    - Identifica contas que não realizam logon há mais de X dias (Padrão: 90 dias)
    - Suporta filtro por tipo de conta: Usuários, Computadores ou Ambos (-AccountType)
    - Suporta delimitar a busca por Unidade Organizacional (-SearchBase)
    - Calcula dias exatos de inatividade e data do último logon registrado
    - Permite desabilitar as contas inativas com segurança e confirmação (-DisableInactive)
    - Exporta relatório consolidado para CSV (-ExportCsv)
    - Retorna objetos estruturados para o pipeline do PowerShell.

.PARAMETER DaysInactive
    Quantidade de dias de inatividade para considerar a conta como obsoleta (Padrão: 90 dias).

.PARAMETER AccountType
    Tipo de objeto a ser auditado: 'User', 'Computer' ou 'All' (Padrão: 'All').

.PARAMETER SearchBase
    DistinguishedName (DN) da Unidade Organizacional (OU) onde a busca deve ser realizada (opcional).

.PARAMETER DisableInactive
    Desativa as contas inativas localizadas (requer confirmação ou switch -Confirm:$false).

.PARAMETER ExportCsv
    Caminho do arquivo CSV para exportação dos dados.

.EXAMPLE
    .\Audit-InactiveAccounts.ps1

.EXAMPLE
    .\Audit-InactiveAccounts.ps1 -DaysInactive 120 -AccountType User

.EXAMPLE
    .\Audit-InactiveAccounts.ps1 -DaysInactive 90 -AccountType Computer -ExportCsv "C:\Temp\Computadores_Inativos.csv"

.EXAMPLE
    .\Audit-InactiveAccounts.ps1 -DaysInactive 180 -DisableInactive -WhatIf
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [int]$DaysInactive = 90,
    [ValidateSet("User", "Computer", "All")]
    [string]$AccountType = "All",
    [string]$SearchBase,
    [switch]$DisableInactive,
    [string]$ExportCsv
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "     AUDITORIA DE CONTAS INATIVAS NO ACTIVE DIRECTORY     " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Validação do módulo ActiveDirectory
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Host "[!] O módulo 'ActiveDirectory' não está instalado neste ambiente." -ForegroundColor Yellow
    Write-Host "    Para instalar as ferramentas RSAT no Windows Server, execute:" -ForegroundColor DarkGray
    Write-Host "    Install-WindowsFeature RSAT-AD-PowerShell" -ForegroundColor Cyan
    Write-Host "    No Windows 10/11:" -ForegroundColor DarkGray
    Write-Host "    Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    return
}

Import-Module ActiveDirectory -ErrorAction SilentlyContinue

$CutoffDate = (Get-Date).AddDays(-$DaysInactive)
Write-Host "Buscando objetos habilitados sem logon desde: " -NoNewline; Write-Host "$($CutoffDate.ToString('yyyy-MM-dd')) ($DaysInactive dias)" -ForegroundColor Yellow
if ($SearchBase) { Write-Host "Escopo da OU: $SearchBase" -ForegroundColor DarkGray }
Write-Host ""

$InactiveList = [System.Collections.Generic.List[PSCustomObject]]::new()
$AdCommonArgs = @{}
if ($SearchBase) { $AdCommonArgs["SearchBase"] = $SearchBase }

# 1. Usuários Inativos
if ($AccountType -eq "User" -or $AccountType -eq "All") {
    Write-Host "[1] Consultando Contas de Usuários Inativos..." -ForegroundColor Yellow
    try {
        $UserFilter = "Enabled -eq '$true' -and (LastLogonDate -lt '$CutoffDate' -or (LastLogonDate -notlike '*' -and whenCreated -lt '$CutoffDate'))"
        $InactiveUsers = Get-ADUser -Filter $UserFilter -Properties LastLogonDate, whenCreated, DisplayName, Description, EmailAddress, DistinguishedName @AdCommonArgs -ErrorAction Stop

        Write-Host "  -> Encontrados: " -NoNewline; Write-Host "$($InactiveUsers.Count) usuário(s) inativo(s)" -ForegroundColor $(if ($InactiveUsers.Count -gt 0) { "Yellow" } else { "Green" })

        foreach ($U in $InactiveUsers) {
            $LastLogon = if ($U.LastLogonDate) { $U.LastLogonDate } else { "Nunca conectou" }
            $Days = if ($U.LastLogonDate) { [math]::Floor(((Get-Date) - $U.LastLogonDate).TotalDays) } else { [math]::Floor(((Get-Date) - $U.whenCreated).TotalDays) }

            $InactiveList.Add([PSCustomObject]@{
                Tipo               = "Usuário"
                Nome               = $U.DisplayName
                Login              = $U.SamAccountName
                UltimoLogon        = if ($U.LastLogonDate) { $U.LastLogonDate.ToString("yyyy-MM-dd HH:mm") } else { "Nunca" }
                CriadoEm           = $U.whenCreated.ToString("yyyy-MM-dd")
                DiasInativo        = $Days
                Descricao          = $U.Description
                DistinguishedName  = $U.DistinguishedName
            })
        }
    } catch {
        Write-Host "  [ERRO] Falha ao consultar usuários: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# 2. Computadores Inativos
if ($AccountType -eq "Computer" -or $AccountType -eq "All") {
    Write-Host ""
    Write-Host "[2] Consultando Computadores / Servidores Inativos..." -ForegroundColor Yellow
    try {
        $CompFilter = "Enabled -eq '$true' -and (LastLogonDate -lt '$CutoffDate' -or (LastLogonDate -notlike '*' -and whenCreated -lt '$CutoffDate'))"
        $InactiveComps = Get-ADComputer -Filter $CompFilter -Properties LastLogonDate, whenCreated, OperatingSystem, Description, DistinguishedName @AdCommonArgs -ErrorAction Stop

        Write-Host "  -> Encontrados: " -NoNewline; Write-Host "$($InactiveComps.Count) computador(es) inativo(s)" -ForegroundColor $(if ($InactiveComps.Count -gt 0) { "Yellow" } else { "Green" })

        foreach ($C in $InactiveComps) {
            $LastLogon = if ($C.LastLogonDate) { $C.LastLogonDate } else { "Nunca conectou" }
            $Days = if ($C.LastLogonDate) { [math]::Floor(((Get-Date) - $C.LastLogonDate).TotalDays) } else { [math]::Floor(((Get-Date) - $C.whenCreated).TotalDays) }

            $InactiveList.Add([PSCustomObject]@{
                Tipo               = "Computador"
                Nome               = $C.Name
                Login              = $C.SamAccountName
                UltimoLogon        = if ($C.LastLogonDate) { $C.LastLogonDate.ToString("yyyy-MM-dd HH:mm") } else { "Nunca" }
                CriadoEm           = $C.whenCreated.ToString("yyyy-MM-dd")
                DiasInativo        = $Days
                Descricao          = "$($C.OperatingSystem) $($C.Description)"
                DistinguishedName  = $C.DistinguishedName
            })
        }
    } catch {
        Write-Host "  [ERRO] Falha ao consultar computadores: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# 3. Exibição Tabular dos Resultados
Write-Host ""
Write-Host "[Itens Inativos Identificados]" -ForegroundColor Yellow
if ($InactiveList.Count -gt 0) {
    $InactiveList | Select-Object -First 25 Tipo, Login, UltimoLogon, CriadoEm, DiasInativo, Descricao | Format-Table -AutoSize
    if ($InactiveList.Count -gt 25) {
        Write-Host "  ... e mais $($InactiveList.Count - 25) item(ns) omitidos na pré-visualização." -ForegroundColor DarkGray
    }
} else {
    Write-Host "  Nenhum objeto inativo encontrado para os critérios selecionados." -ForegroundColor Green
}

# 4. Desativação de Objetos Inativos (Se solicitado)
if ($DisableInactive -and $InactiveList.Count -gt 0) {
    Write-Host ""
    Write-Host "[4] Desativando Contas Inativas:" -ForegroundColor Yellow

    foreach ($Item in $InactiveList) {
        if ($PSCmdlet.ShouldProcess("$($Item.Tipo): $($Item.Login)", "Desabilitar conta no Active Directory")) {
            try {
                Set-ADObject -Identity $Item.DistinguishedName -Enabled $false -ErrorAction Stop
                Write-Host "  [OK] $($Item.Tipo) '$($Item.Login)' foi desabilitado com sucesso." -ForegroundColor Green
            } catch {
                Write-Host "  [FALHA] Não foi possível desabilitar '$($Item.Login)': $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    }
}

# 5. Exportação para CSV
if ($ExportCsv -and $InactiveList.Count -gt 0) {
    try {
        $InactiveList | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding utf8
        Write-Host ""
        Write-Host "[OK] Relatório CSV salvo em: $ExportCsv" -ForegroundColor Green
    } catch {
        Write-Host ""
        Write-Host "[ERRO] Falha ao exportar CSV: $($_.Exception.Message)" -ForegroundColor Red
    }
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Total de objetos inativos: $($InactiveList.Count)" -ForegroundColor White
Write-Host "==========================================================" -ForegroundColor Cyan

return $InactiveList
