<#
.SYNOPSIS
    Coleta e sumariza erros críticos e de sistema ocorridos recentemente nos Logs de Eventos do Windows.

.DESCRIPTION
    Examina os logs 'System' e 'Application' em busca de eventos com nível de gravidade
    'Erro' e 'Crítico' nas últimas X horas. Agrupa os problemas mais frequentes para
    acelerar o diagnóstico de incidentes pelo administrador de TI.

.PARAMETER Hours
    Quantidade de horas retrospectivas para analisar (Padrão: 24 horas).

.PARAMETER MaxEvents
    Número máximo de eventos detalhados a exibir (Padrão: 30).

.PARAMETER LogNames
    Nomes dos canais de logs a verificar (Padrão: 'System', 'Application').

.PARAMETER ExportCsv
    Caminho opcional para exportar a listagem de erros em formato CSV.

.EXAMPLE
    .\Get-RecentEventErrors.ps1

.EXAMPLE
    .\Get-RecentEventErrors.ps1 -Hours 48 -MaxEvents 50

.EXAMPLE
    .\Get-RecentEventErrors.ps1 -Hours 12 -ExportCsv "C:\Temp\server_errors.csv"
#>

[CmdletBinding()]
param(
    [int]$Hours = 24,
    [int]$MaxEvents = 30,
    [string[]]$LogNames = @("System", "Application"),
    [string]$ExportCsv
)

$StartTime = (Get-Date).AddHours(-$Hours)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "    VARREDURA DE ERROS NOS LOGS DE EVENTOS DO WINDOWS     " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Intervalo analisado : Últimas $Hours horas (Desde $($StartTime.ToString('yyyy-MM-dd HH:mm:ss')))" -ForegroundColor White
Write-Host "Logs consultados    : $( $LogNames -join ', ' )" -ForegroundColor White
Write-Host "Consultando eventos... aguarde..." -ForegroundColor DarkGray
Write-Host ""

$AllErrors = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($LogName in $LogNames) {
    try {
        # Level 1 = Crítico, Level 2 = Erro
        $FilterHashTable = @{
            LogName   = $LogName
            Level     = @(1, 2)
            StartTime = $StartTime
        }

        $Events = Get-WinEvent -FilterHashtable $FilterHashTable -MaxEvents 500 -ErrorAction SilentlyContinue

        if ($Events) {
            foreach ($Evt in $Events) {
                $LevelName = switch ($Evt.Level) {
                    1 { "Crítico" }
                    2 { "Erro" }
                    default { "Aviso" }
                }

                $CleanMessage = if ($Evt.Message) {
                    $TempMsg = ($Evt.Message -replace "[\r\n]+", " ").Trim()
                    if ($TempMsg.Length -gt 140) { $TempMsg.Substring(0, 137) + "..." } else { $TempMsg }
                } else { "Sem mensagem disponível." }

                $AllErrors.Add([PSCustomObject]@{
                    DataHora   = $Evt.TimeCreated
                    Log        = $LogName
                    Nivel      = $LevelName
                    Origem     = $Evt.ProviderName
                    IDEvento   = $Evt.Id
                    Mensagem   = $CleanMessage
                })
            }
        }
    }
    catch {
        Write-Host "[-] Aviso: Falha ao ler canal '$LogName': $($_.Exception.Message)" -ForegroundColor DarkGray
    }
}

if ($AllErrors.Count -eq 0) {
    Write-Host "[OK] Nenhum evento de Erro ou Crítico encontrado nas últimas $Hours horas!" -ForegroundColor Green
    Write-Host "==========================================================" -ForegroundColor Cyan
    return
}

# 1. Resumo por frequência (Top Origens de Erros)
Write-Host "[1] Resumo dos Erros Mais Frequentes por Origem e ID:" -ForegroundColor Yellow
$Summary = $AllErrors | Group-Object -Property Origem, IDEvento | Sort-Object -Property Count -Descending | Select-Object -First 10

foreach ($Grp in $Summary) {
    Write-Host "  Ocorrências: $($Grp.Count.ToString().PadRight(4)) | " -NoNewline -ForegroundColor Cyan
    Write-Host "$($Grp.Name)" -ForegroundColor White
}

# 2. Últimos eventos detalhados
Write-Host ""
Write-Host "[2] Detalhes dos Últimos $( [math]::Min($MaxEvents, $AllErrors.Count) ) Eventos Registrados:" -ForegroundColor Yellow

$RecentDetails = $AllErrors | Sort-Object -Property DataHora -Descending | Select-Object -First $MaxEvents

foreach ($Item in $RecentDetails) {
    $LColor = if ($Item.Nivel -eq "Crítico") { "Red" } else { "Yellow" }
    Write-Host "  [$($Item.DataHora.ToString('yyyy-MM-dd HH:mm:ss'))] " -ForegroundColor DarkGray -NoNewline
    Write-Host "[$($Item.Nivel.ToUpper())] " -ForegroundColor $LColor -NoNewline
    Write-Host "Log: $($Item.Log) | Origem: $($Item.Origem) (ID: $($Item.IDEvento))" -ForegroundColor White
    Write-Host "    -> $($Item.Mensagem)" -ForegroundColor DarkCyan
}

if ($ExportCsv) {
    $AllErrors | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Host ""
    Write-Host "Relatório completo exportado para CSV: $ExportCsv" -ForegroundColor Green
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Total de eventos de erro encontrados: $($AllErrors.Count)" -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

return $AllErrors
