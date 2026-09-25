$TempPath = Join-Path $env:LOCALAPPDATA "Temp"

if (Test-Path $TempPath) {
    Get-ChildItem -Path $TempPath -Force -ErrorAction SilentlyContinue |
        Remove-Item -Force -Recurse -ErrorAction SilentlyContinue

    Write-Host "Arquivos temporários limpos com sucesso!" -ForegroundColor Green
}
else {
    Write-Host "A pasta Temp não foi encontrada." -ForegroundColor Yellow
}