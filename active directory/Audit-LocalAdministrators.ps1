<#
.SYNOPSIS
    Audita todos os membros do grupo de Administradores Locais do servidor.

.DESCRIPTION
    Lista os usuários e grupos que possuem privilégios administrativos na máquina local.
    Identifica se a conta é Local, do Domínio (AD) ou do Azure AD, e destaca SIDs órfãos
    (contas que foram excluídas do domínio mas continuam com permissões residuais no servidor).

.PARAMETER ComputerName
    Nome do computador para auditar (Padrão: localhost).

.EXAMPLE
    .\Audit-LocalAdministrators.ps1

.EXAMPLE
    .\Audit-LocalAdministrators.ps1 -ComputerName "SRV-FILE-01"
#>

[CmdletBinding()]
param(
    [string]$ComputerName = $env:COMPUTERNAME
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "     AUDITORIA DO GRUPO ADMINISTRADORES LOCAIS           " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Alvo da auditoria: $ComputerName" -ForegroundColor White
Write-Host ""

$Results = [System.Collections.Generic.List[PSCustomObject]]::new()

try {
    # Resolver o nome do grupo de Administradores pelo SID bem-conhecido S-1-5-32-544
    # Isso garante compatibilidade com sistemas em Inglês (Administrators), Português (Administradores), etc.
    $AdminSid = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
    $GroupNameResolved = ($AdminSid.Translate([System.Security.Principal.NTAccount]).Value -split '\\')[-1]

    if ($ComputerName -eq $env:COMPUTERNAME -or $ComputerName -eq "localhost") {
        $Members = Get-LocalGroupMember -Group $GroupNameResolved -ErrorAction Stop
    } else {
        $Members = Invoke-Command -ComputerName $ComputerName -ArgumentList $GroupNameResolved -ScriptBlock {
            param($TargetGroup)
            Get-LocalGroupMember -Group $TargetGroup
        } -ErrorAction Stop
    }

    foreach ($Member in $Members) {
        $Name = $Member.Name
        $Class = $Member.ObjectClass
        $Source = $Member.PrincipalSource
        $Sid = $Member.SID.Value

        # Identificar se é conta órfã (SID não resolvido)
        $IsOrphaned = $false
        if ($Name -match "^S-1-5-") {
            $IsOrphaned = $true
            $StatusTag = "[ÓRFÃO / DELETADO]"
            $Color = "Red"
        } elseif ($Source -eq "Local") {
            $StatusTag = "[LOCAL]"
            $Color = "Yellow"
        } else {
            $StatusTag = "[DOMÍNIO / $Source]"
            $Color = "Green"
        }

        Write-Host "  $StatusTag " -ForegroundColor $Color -NoNewline
        Write-Host "$Name " -ForegroundColor White -NoNewline
        Write-Host "($Class) - SID: $Sid" -ForegroundColor DarkGray

        $Results.Add([PSCustomObject]@{
            Servidor         = $ComputerName
            Nome             = $Name
            TipoObjeto       = $Class
            Origem           = $Source
            SID              = $Sid
            Orfao            = $IsOrphaned
        })
    }
}
catch {
    Write-Host "Erro ao consultar o grupo de Administradores: $($_.Exception.Message)" -ForegroundColor Red
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Total de membros no grupo Administradores: $($Results.Count)" -ForegroundColor Cyan
$OrphanCount = ($Results | Where-Object { $_.Orfao }).Count
if ($OrphanCount -gt 0) {
    Write-Host "ALERTA: Foram detectados $OrphanCount SID(s) órfão(s). Recomenda-se remover contas deletadas." -ForegroundColor Red
}
Write-Host "==========================================================" -ForegroundColor Cyan

return $Results
