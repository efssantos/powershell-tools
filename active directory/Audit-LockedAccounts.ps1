<#
.SYNOPSIS
    Localiza e opcionalmente desbloqueia contas de usuário bloqueadas no Active Directory.

.DESCRIPTION
    Consulta o Active Directory por contas com atributo de bloqueio (LockedOut).
    Exibe detalhes como nome, login, última tentativa inválida de senha e horário do bloqueio.
    Possui opção para desbloquear uma ou todas as contas encontradas.

.PARAMETER UnlockAll
    Se especificado, desbloqueia automaticamente todas as contas bloqueadas encontradas.

.PARAMETER SpecificUser
    SamAccountName de um usuário específico para verificar ou desbloquear.

.EXAMPLE
    .\Audit-LockedAccounts.ps1

.EXAMPLE
    .\Audit-LockedAccounts.ps1 -UnlockAll

.EXAMPLE
    .\Audit-LockedAccounts.ps1 -SpecificUser "joao.silva"
#>

[CmdletBinding()]
param(
    [switch]$UnlockAll,
    [string]$SpecificUser
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "       AUDITORIA DE CONTAS BLOQUEADAS (ACTIVE DIRECTORY)   " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Verificar se o módulo ActiveDirectory está disponível
if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    Write-Host "[!] O módulo 'ActiveDirectory' não está instalado neste servidor/estação." -ForegroundColor Yellow
    Write-Host "    Para instalar as ferramentas RSAT no Windows Server, execute:" -ForegroundColor DarkGray
    Write-Host "    Install-WindowsFeature RSAT-AD-PowerShell" -ForegroundColor Cyan
    Write-Host "    No Windows 10/11:" -ForegroundColor DarkGray
    Write-Host "    Add-WindowsCapability -Online -Name Rsat.ActiveDirectory.DS-LDS.Tools~~~~0.0.1.0" -ForegroundColor Cyan
    Write-Host "==========================================================" -ForegroundColor Cyan
    return
}

Import-Module ActiveDirectory -ErrorAction SilentlyContinue

Write-Host "Consultando o catálogo do Active Directory..." -ForegroundColor DarkGray
Write-Host ""

$LockedAccounts = @()

try {
    if ($SpecificUser) {
        $User = Get-ADUser -Identity $SpecificUser -Properties LockedOut, badPwdCount, lastBadPasswordAttempt, DisplayName -ErrorAction Stop
        if ($User.LockedOut) {
            $LockedAccounts = @($User)
        } else {
            Write-Host "O usuário '$SpecificUser' NÃO está bloqueado." -ForegroundColor Green
            return
        }
    } else {
        $LockedAccounts = Search-ADAccount -LockedOut -UsersOnly -ErrorAction Stop |
            Get-ADUser -Properties badPwdCount, lastBadPasswordAttempt, DisplayName, AccountLockoutTime
    }
} catch {
    Write-Host "Erro ao consultar o Active Directory: $($_.Exception.Message)" -ForegroundColor Red
    return
}

if (-not $LockedAccounts -or $LockedAccounts.Count -eq 0) {
    Write-Host "Nenhuma conta de usuário está bloqueada no momento!" -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Cyan
    return
}

Write-Host "Foram encontradas $( $LockedAccounts.Count ) conta(s) bloqueada(s):" -ForegroundColor Yellow
Write-Host ""

$Results = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($Acc in $LockedAccounts) {
    Write-Host "  Usuário: " -NoNewline
    Write-Host "$($Acc.SamAccountName)" -ForegroundColor Cyan -NoNewline
    Write-Host " ($($Acc.DisplayName))" -ForegroundColor White
    Write-Host "    Tentativas incorretas de senha: $($Acc.badPwdCount)" -ForegroundColor DarkGray
    Write-Host "    Última tentativa incorreta    : $($Acc.lastBadPasswordAttempt)" -ForegroundColor DarkGray

    $StatusDesbloqueio = "Bloqueada"

    if ($UnlockAll) {
        try {
            Unlock-ADAccount -Identity $Acc.SamAccountName -ErrorAction Stop
            Write-Host "    -> [SUCESSO] Conta desbloqueada com sucesso!" -ForegroundColor Green
            $StatusDesbloqueio = "Desbloqueada"
        } catch {
            Write-Host "    -> [FALHA] Não foi possível desbloquear: $($_.Exception.Message)" -ForegroundColor Red
            $StatusDesbloqueio = "Falha ao desbloquear"
        }
    }

    $Results.Add([PSCustomObject]@{
        SamAccountName         = $Acc.SamAccountName
        Nome                   = $Acc.DisplayName
        TentativasFalhas       = $Acc.badPwdCount
        UltimaFalha            = $Acc.lastBadPasswordAttempt
        Status                 = $StatusDesbloqueio
    })
    Write-Host "  ----------------------------------------------------" -ForegroundColor DarkGray
}

if (-not $UnlockAll) {
    Write-Host ""
    Write-Host "Dica: Para desbloquear automaticamente todas as contas listadas, use o parâmetro -UnlockAll" -ForegroundColor DarkGray
}

Write-Host "==========================================================" -ForegroundColor Cyan

return $Results
