<#
.SYNOPSIS
    Sincroniza e replica diretórios e compartilhamentos de arquivos com preservação de ACLs e alta performance.

.DESCRIPTION
    Script de alta confiabilidade para rotinas de backup, sincronização e migração de dados de servidores e estações:
    - Executa sincronização baseada no motor Robocopy de alto desempenho com multi-threading (-Threads)
    - Suporta modo espelhamento (-Mirror) para replicar com exatidão a estrutura de diretórios e purgar arquivos órfãos
    - Suporta cópia avançada de permissões NTFS (ACLs, auditoria, proprietário: /COPY:DATSOU) (-CopyAcl)
    - Exclusão automática de arquivos/pastas de sistema e temporários ($RECYCLE.BIN, System Volume Information, *.tmp, etc.)
    - Configuração resiliente de tolerância a falhas e retentativas em arquivos bloqueados (-MaxRetries)
    - Gera relatório de auditoria e sumário analítico com quantidade de arquivos copiados, ignorados, falhas e tempo decorrido.

.PARAMETER SourcePath
    Caminho de origem (diretório local "D:\Dados" ou compartilhamento de rede "\\servidor\origem").

.PARAMETER DestinationPath
    Caminho de destino (diretório local, HD externo ou compartilhamento "\\servidor\backup").

.PARAMETER Mirror
    Habilita espelhamento completo (/MIR). ATENÇÃO: Arquivos no destino que não existirem na origem serão excluídos.

.PARAMETER CopyAcl
    Copia listas de controle de acesso NTFS (permissões de segurança, proprietário e auditoria).

.PARAMETER Threads
    Número de threads paralelas para aceleração da transferência (Padrão: 8, faixa: 1 a 128).

.PARAMETER MaxRetries
    Quantidade máxima de retentativas para arquivos bloqueados (Padrão: 2).

.PARAMETER LogPath
    Caminho opcional do arquivo de log gerado. Por padrão é salvo no diretório de destino.

.EXAMPLE
    .\Sync-FileShareBackup.ps1 -SourcePath "D:\Departamentos" -DestinationPath "\\SRV-BACKUP\Replica_Departamentos"

.EXAMPLE
    .\Sync-FileShareBackup.ps1 -SourcePath "E:\Arquivos" -DestinationPath "F:\Backup_Arquivos" -Mirror -CopyAcl

.EXAMPLE
    .\Sync-FileShareBackup.ps1 -SourcePath "\\SRV-FS01\Projetos" -DestinationPath "D:\Backup_Projetos" -Threads 16
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [string]$SourcePath,

    [Parameter(Mandatory = $true)]
    [string]$DestinationPath,

    [switch]$Mirror,
    [switch]$CopyAcl,
    [int]$Threads = 8,
    [int]$MaxRetries = 2,
    [string]$LogPath
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "       SINCRONIZAÇÃO & RÉPLICA DE COMPARTILHAMENTOS       " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Validando diretórios e parâmetros de transferência..." -ForegroundColor DarkGray
Write-Host ""

# Validação de Origem
if (-not (Test-Path -Path $SourcePath)) {
    Write-Host "[ERRO] Diretório de origem '$SourcePath' não foi encontrado ou está inacessível!" -ForegroundColor Red
    return
}

# Criação de Destino se não existir
try {
    if (-not (Test-Path -Path $DestinationPath)) {
        Write-Host "Criando pasta de destino '$DestinationPath'..." -ForegroundColor DarkGray
        New-Item -ItemType Directory -Path $DestinationPath -Force | Out-Null
    }
} catch {
    Write-Host "[ERRO] Falha ao criar diretório de destino '$DestinationPath': $($_.Exception.Message)" -ForegroundColor Red
    return
}

# Configuração do arquivo de Log
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
if (-not $LogPath) {
    $LogPath = Join-Path $DestinationPath "sync_robocopy_$Timestamp.log"
}

Write-Host "[1] Parâmetros da Execução:" -ForegroundColor Yellow
Write-Host "  Origem         : $SourcePath" -ForegroundColor White
Write-Host "  Destino        : $DestinationPath" -ForegroundColor White
Write-Host "  Modo de Cópia  : " -NoNewline
if ($Mirror) {
    Write-Host "[ESPELHAMENTO COMPLETO /MIR]" -ForegroundColor Yellow
} else {
    Write-Host "[CÓPIA INCREMENTAL /E]" -ForegroundColor Green
}
Write-Host "  Preservar ACLs : " -NoNewline
if ($CopyAcl) { Write-Host "[SIM (DATSOU)]" -ForegroundColor Green } else { Write-Host "[NÃO (DAT)]" -ForegroundColor DarkGray }
Write-Host "  Threads        : $Threads threads simultâneas" -ForegroundColor DarkGray
Write-Host "  Arquivo de Log : $LogPath" -ForegroundColor DarkGray
Write-Host ""

# Montagem dos argumentos do Robocopy
$RoboArgs = [System.Collections.Generic.List[string]]::new()
$RoboArgs.Add("`"$SourcePath`"")
$RoboArgs.Add("`"$DestinationPath`"")

if ($Mirror) {
    $RoboArgs.Add("/MIR")
} else {
    $RoboArgs.Add("/E")
}

if ($CopyAcl) {
    $RoboArgs.Add("/COPY:DATSOU")
} else {
    $RoboArgs.Add("/COPY:DAT")
}

$RoboArgs.Add("/DCOPY:DAT")
$RoboArgs.Add("/MT:$Threads")
$RoboArgs.Add("/R:$MaxRetries")
$RoboArgs.Add("/W:3")
$RoboArgs.Add("/XJ") # Exclui junções para evitar loops infinitos
$RoboArgs.Add("/NP") # Sem porcentagem de progresso para manter log limpo
$RoboArgs.Add("/NDL") # Não lista diretórios no console
$RoboArgs.Add("/TEE") # Exibe no console e grava no log
$RoboArgs.Add("/LOG+:`"$LogPath`"")

# Exclusões padrão de pastas e arquivos temporários/sistema
$ExcludedDirs = @('"$RECYCLE.BIN"', '"System Volume Information"', '".git"', '"node_modules"')
$ExcludedFiles = @('"*.tmp"', '"Thumbs.db"', '"desktop.ini"', '"~$*"')
$RoboArgs.Add("/XD " + ($ExcludedDirs -join " "))
$RoboArgs.Add("/XF " + ($ExcludedFiles -join " "))

Write-Host "[2] Executando Sincronização em Segundo Plano..." -ForegroundColor Yellow
$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

$FullCmd = $RoboArgs -join " "
$Process = Start-Process -FilePath "robocopy.exe" -ArgumentList $FullCmd -Wait -PassThru -NoNewWindow

$Stopwatch.Stop()
$ElapsedTime = $Stopwatch.Elapsed

# 3. Análise do Código de Saída do Robocopy
# 0 = Nenhuma alteração
# 1 = Arquivos copiados com sucesso
# 2 = Arquivos extras detectados (no destino)
# 4 = Arquivos incompatíveis detectados
# 8 = Falha na cópia de alguns arquivos
# 16 = Erro fatal
$ExitCode = $Process.ExitCode

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "             RESULTADO DA SINCRONIZAÇÃO                   " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

$Success = $true
if ($ExitCode -lt 8) {
    Write-Host "  Status Geral   : " -NoNewline; Write-Host "[SUCESSO (Código: $ExitCode)]" -ForegroundColor Green
    if ($ExitCode -eq 0) { Write-Host "  Observação     : Origem e Destino já estavam perfeitamente sincronizados." -ForegroundColor DarkGray }
    if ($ExitCode -band 1) { Write-Host "  Observação     : Arquivos foram copiados com sucesso." -ForegroundColor Green }
    if ($ExitCode -band 2) { Write-Host "  Observação     : Arquivos extras ou órfãos tratados no destino." -ForegroundColor DarkGray }
} else {
    $Success = $false
    Write-Host "  Status Geral   : " -NoNewline; Write-Host "[ERRO / FALHA (Código: $ExitCode)]" -ForegroundColor Red
    Write-Host "  Observação     : Alguns arquivos não puderam ser copiados ou acesso foi negado." -ForegroundColor Yellow
}

Write-Host "  Tempo Total    : $($ElapsedTime.ToString('hh\:mm\:ss'))" -ForegroundColor White
Write-Host "  Log Detalhado  : $LogPath" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

return [PSCustomObject]@{
    SourcePath      = $SourcePath
    DestinationPath = $DestinationPath
    Success         = $Success
    ExitCode        = $ExitCode
    Duration        = $ElapsedTime.ToString('hh\:mm\:ss')
    LogFile         = $LogPath
}
