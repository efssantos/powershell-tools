<#
.SYNOPSIS
    Localiza rapidamente os maiores arquivos em um diretório ou partição de disco.

.DESCRIPTION
    Ideal para investigar falta de espaço em disco em servidores de arquivos, banco de dados ou logs.
    Varre recursivamente o caminho especificado e exibe os arquivos que excedem o tamanho definido.

.PARAMETER Path
    Caminho ou unidade de disco para analisar (Padrão: "C:\").

.PARAMETER MinSizeMB
    Tamanho mínimo em Megabytes para filtrar os arquivos (Padrão: 500 MB).

.PARAMETER Top
    Quantidade máxima de arquivos a exibir na lista ordenada (Padrão: 25).

.PARAMETER ExportCsv
    Caminho opcional para exportar os resultados em formato CSV.

.EXAMPLE
    .\Find-LargeFiles.ps1

.EXAMPLE
    .\Find-LargeFiles.ps1 -Path "D:\Data" -MinSizeMB 1024 -Top 50

.EXAMPLE
    .\Find-LargeFiles.ps1 -Path "C:\inetpub" -MinSizeMB 100 -ExportCsv "C:\Temp\large_iis_files.csv"
#>

[CmdletBinding()]
param(
    [string]$Path = "C:\",
    [int]$MinSizeMB = 500,
    [int]$Top = 25,
    [string]$ExportCsv
)

if (-not (Test-Path -Path $Path)) {
    Write-Error "O caminho '$Path' não foi encontrado."
    return
}

$MinSizeBytes = [int64]$MinSizeMB * 1MB

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "         BUSCA DE GRANDES ARQUIVOS EM DISCO               " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Caminho analisado : $Path" -ForegroundColor White
Write-Host "Tamanho mínimo    : $MinSizeMB MB ($([math]::Round($MinSizeMB / 1024, 2)) GB)" -ForegroundColor White
Write-Host "Limite de exibição: Top $Top maiores arquivos" -ForegroundColor White
Write-Host "Aguarde, varrendo diretórios..." -ForegroundColor DarkGray
Write-Host ""

$Stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

# Busca otimizada evitando travar em acessos negados
$FoundFiles = Get-ChildItem -Path $Path -Recurse -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Length -ge $MinSizeBytes } |
    Sort-Object -Property Length -Descending |
    Select-Object -First $Top

$Stopwatch.Stop()

if (-not $FoundFiles) {
    Write-Host "Nenhum arquivo maior que $MinSizeMB MB foi encontrado no caminho especificado." -ForegroundColor Green
    return
}

$Results = [System.Collections.Generic.List[PSCustomObject]]::new()
$Counter = 1

foreach ($File in $FoundFiles) {
    $SizeMB = [math]::Round($File.Length / 1MB, 2)
    $SizeGB = [math]::Round($File.Length / 1GB, 2)
    $SizeFormatted = if ($SizeGB -ge 1) { "$SizeGB GB" } else { "$SizeMB MB" }

    Write-Host "[$Counter] " -ForegroundColor Yellow -NoNewline
    Write-Host "$($File.Name) " -ForegroundColor White -NoNewline
    Write-Host "[$SizeFormatted]" -ForegroundColor Cyan
    Write-Host "    Caminho: $($File.FullName)" -ForegroundColor DarkGray
    Write-Host "    Modificado em: $($File.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'))" -ForegroundColor DarkGray

    $Results.Add([PSCustomObject]@{
        Posicao        = $Counter
        Nome           = $File.Name
        TamanhoMB      = $SizeMB
        TamanhoGB      = $SizeGB
        TamanhoFormatado = $SizeFormatted
        UltimaModificacao = $File.LastWriteTime
        CaminhoCompleto = $File.FullName
        Extensao       = $File.Extension
    })

    $Counter++
}

Write-Host ""
Write-Host "Varredura concluída em $([math]::Round($Stopwatch.Elapsed.TotalSeconds, 2)) segundos." -ForegroundColor DarkGray

if ($ExportCsv) {
    $Results | Export-Csv -Path $ExportCsv -NoTypeInformation -Encoding UTF8
    Write-Host "Relatório exportado para CSV com sucesso: $ExportCsv" -ForegroundColor Green
}

Write-Host "==========================================================" -ForegroundColor Cyan

return $Results
