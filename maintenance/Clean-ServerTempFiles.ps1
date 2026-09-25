<#
.SYNOPSIS
    Realiza uma limpeza aprofundada e segura de arquivos temporários e caches em servidores Windows.

.DESCRIPTION
    Limpa de forma controlada:
    - Diretórios temporários de usuários (%LOCALAPPDATA%\Temp e perfis em C:\Users)
    - Diretório temporário do Windows (C:\Windows\Temp)
    - Cache de download do Windows Update (C:\Windows\SoftwareDistribution\Download)
    - Dumps de memória e travamentos (Minidumps e CrashDumps)
    - Logs antigos do IIS (opcional, com mais de X dias)
    - Esvazia a Lixeira do Windows
    Calcula e exibe a quantidade total de espaço em disco liberado.

.PARAMETER DaysOld
    Idade mínima em dias para exclusão de arquivos temporários (Padrão: 3 dias, evitando conflito com arquivos em uso).

.PARAMETER CleanUpdateCache
    Habilita a limpeza do cache de pacotes baixados pelo Windows Update.

.PARAMETER CleanIISLogs
    Habilita a exclusão de arquivos de log do IIS (.log) mais antigos que $DaysOld.

.EXAMPLE
    .\Clean-ServerTempFiles.ps1

.EXAMPLE
    .\Clean-ServerTempFiles.ps1 -DaysOld 7 -CleanUpdateCache -CleanIISLogs
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [int]$DaysOld = 3,
    [switch]$CleanUpdateCache,
    [switch]$CleanIISLogs
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "         LIMPEZA DE ARQUIVOS TEMPORÁRIOS & CACHES         " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Arquivos anteriores a $DaysOld dias serão removidos com segurança." -ForegroundColor DarkGray
Write-Host ""

$CutoffDate = (Get-Date).AddDays(-$DaysOld)
$Script:TotalBytesCleaned = 0
$Script:TotalFilesRemoved = 0

function Remove-TargetFolderContent {
    param(
        [string]$Path,
        [string]$Description,
        [datetime]$FilterDate = $CutoffDate,
        [string]$FilterExtension = "*",
        [bool]$IgnoreAge = $false
    )

    if (-not (Test-Path -Path $Path)) {
        return
    }

    Write-Host "Limpar: $Description ($Path)..." -ForegroundColor Yellow
    $Items = Get-ChildItem -Path $Path -Recurse -File -Filter $FilterExtension -Force -ErrorAction SilentlyContinue

    if ($IgnoreAge) {
        $EligibleItems = $Items
    } else {
        $EligibleItems = $Items | Where-Object { $_.LastWriteTime -lt $FilterDate }
    }

    $Count = 0
    $Bytes = 0

    foreach ($Item in $EligibleItems) {
        try {
            $ItemSize = $Item.Length
            Remove-Item -Path $Item.FullName -Force -ErrorAction Stop
            $Bytes += $ItemSize
            $Count++
        } catch {
            # Arquivo provavelmente bloqueado por outro processo em execução
        }
    }

    $FreedMB = [math]::Round($Bytes / 1MB, 2)
    Write-Host "  -> $Count arquivos removidos ($FreedMB MB liberados)" -ForegroundColor Green

    $Script:TotalBytesCleaned += $Bytes
    $Script:TotalFilesRemoved += $Count
}

# 1. Pasta temporária do Windows
Remove-TargetFolderContent -Path "$env:SystemRoot\Temp" -Description "Windows Temp"

# 2. Pasta temporária do usuário atual
Remove-TargetFolderContent -Path "$env:LOCALAPPDATA\Temp" -Description "User Temp (Perfil Atual)"

# 3. Pastas temporárias de outros perfis em C:\Users (requer privilégios de Admin)
$UserProfiles = Get-ChildItem -Path "C:\Users" -Directory -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @("All Users", "Default", "Default User", "Public") }

foreach ($Profile in $UserProfiles) {
    $UserProfileTemp = Join-Path $Profile.FullName "AppData\Local\Temp"
    if (Test-Path $UserProfileTemp) {
        Remove-TargetFolderContent -Path $UserProfileTemp -Description "Temp do perfil $($Profile.Name)"
    }
}

# 4. Crash Dumps e Minidumps
Remove-TargetFolderContent -Path "$env:SystemRoot\Minidump" -Description "Minidumps de Tela Azul (BSOD)" -IgnoreAge $true
Remove-TargetFolderContent -Path "$env:LOCALAPPDATA\CrashDumps" -Description "Crash Dumps de Aplicações" -IgnoreAge $true

# 5. Cache de Downloads do Windows Update
if ($CleanUpdateCache) {
    Write-Host ""
    Write-Host "Verificando Cache do Windows Update..." -ForegroundColor Yellow
    $UpdateCachePath = "$env:SystemRoot\SoftwareDistribution\Download"
    Remove-TargetFolderContent -Path $UpdateCachePath -Description "SoftwareDistribution\Download" -IgnoreAge $true
}

# 6. Logs antigos do IIS
if ($CleanIISLogs) {
    $IISLogPath = "$env:SystemDrive\inetpub\logs\LogFiles"
    if (Test-Path $IISLogPath) {
        Write-Host ""
        Write-Host "Verificando Logs antigos do IIS..." -ForegroundColor Yellow
        Remove-TargetFolderContent -Path $IISLogPath -Description "Logs do IIS (> $DaysOld dias)" -FilterExtension "*.log"
    }
}

# 7. Esvaziar Lixeira do Windows
Write-Host ""
Write-Host "Esvaziando Lixeira de todos os discos..." -ForegroundColor Yellow
try {
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    Write-Host "  -> Lixeira esvaziada com sucesso." -ForegroundColor Green
} catch {
    Write-Host "  -> Falha ou lixeira já vazia." -ForegroundColor DarkGray
}

# Resumo Final
$TotalMB = [math]::Round($Script:TotalBytesCleaned / 1MB, 2)
$TotalGB = [math]::Round($Script:TotalBytesCleaned / 1GB, 2)

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "RESUMO DA LIMPEZA:" -ForegroundColor Cyan
Write-Host "  Total de arquivos excluídos: $Script:TotalFilesRemoved" -ForegroundColor White
Write-Host "  Total de espaço liberado   : $TotalMB MB ($TotalGB GB)" -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
