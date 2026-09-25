<#
.SYNOPSIS
    Instala softwares de forma silenciosa e remota (ou local) em computadores de usuários.

.DESCRIPTION
    Permite implantar programas remotamente em estações de trabalho via WinRM/PowerShell Remoting ou localmente.
    Suporta dois métodos de instalação:
    1. Winget (Windows Package Manager): Instala pacotes do repositório oficial (ex: Google.Chrome, 7zip.7zip, Adobe.Acrobat.Reader.64-bit).
    2. Instalador MSI / EXE (Rede ou Local): Executa instaladores em modo silencioso (/qn para MSI, parâmetros silenciosos para EXE).

.PARAMETER ComputerName
    Nome(s) ou endereço(s) IP dos computadores de destino. Padrão: "localhost".

.PARAMETER PackageId
    ID do pacote no catálogo do Winget (ex: 'Google.Chrome', 'Mozilla.Firefox', '7zip.7zip', 'AnyDesk.AnyDesk').

.PARAMETER InstallerPath
    Caminho local ou caminho de rede UNC para o arquivo .msi ou .exe (ex: '\\servidor\softwares\agente.msi').

.PARAMETER InstallerArgs
    Argumentos de instalação silenciosa para o executável. Padrão: '/qn /norestart' para MSI, '/S' para EXE.

.PARAMETER Credential
    Credenciais administrativas opcionais para autenticação nas máquinas remotas.

.EXAMPLE
    .\Install-RemoteSoftware.ps1 -PackageId "Google.Chrome"

.EXAMPLE
    .\Install-RemoteSoftware.ps1 -ComputerName "PC-RH-01", "PC-RH-02" -PackageId "7zip.7zip"

.EXAMPLE
    .\Install-RemoteSoftware.ps1 -ComputerName "PC-DEV-05" -InstallerPath "\\srv-fs01\deploy\Agent.msi"
#>

[CmdletBinding(DefaultParameterSetName = "Winget")]
param(
    [Parameter(Position = 0)]
    [string[]]$ComputerName = @("localhost"),

    [Parameter(ParameterSetName = "Winget", Mandatory = $true)]
    [string]$PackageId,

    [Parameter(ParameterSetName = "CustomInstaller", Mandatory = $true)]
    [string]$InstallerPath,

    [Parameter(ParameterSetName = "CustomInstaller")]
    [string]$InstallerArgs,

    [System.Management.Automation.PSCredential]$Credential
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "       INSTALAÇÃO REMOTA / SILENCIOSA DE SOFTWARES        " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

# Bloco de script a ser executado no alvo (Local ou Remoto)
$InstallScriptBlock = {
    param($PkgId, $InstPath, $InstArgs)

    $Result = [PSCustomObject]@{
        Computador    = $env:COMPUTERNAME
        TipoMetodo    = ""
        Alvo          = ""
        Sucesso       = $false
        CodigoSaida   = -1
        Mensagem      = ""
    }

    # Método 1: Winget
    if ($PkgId) {
        $Result.TipoMetodo = "Winget"
        $Result.Alvo = $PkgId

        # Localizar o executável do winget
        $WingetExe = (Get-Command winget.exe -ErrorAction SilentlyContinue).Source
        if (-not $WingetExe) {
            # Tentar caminho padrão do AppX
            $AppxWinget = Get-ChildItem -Path "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($AppxWinget) { $WingetExe = $AppxWinget.FullName }
        }

        if (-not $WingetExe) {
            $Result.Mensagem = "O utilitário 'winget' não foi encontrado neste sistema."
            return $Result
        }

        try {
            $Process = Start-Process -FilePath $WingetExe -ArgumentList "install --id `"$PkgId`" --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity" -Wait -PassThru -NoNewWindow
            $Result.CodigoSaida = $Process.ExitCode
            if ($Process.ExitCode -eq 0 -or $Process.ExitCode -eq 3010) {
                $Result.Sucesso = $true
                $Result.Mensagem = "Software '$PkgId' instalado com sucesso via Winget."
            } else {
                $Result.Mensagem = "Winget finalizou com código de erro: $($Process.ExitCode)."
            }
        } catch {
            $Result.Mensagem = "Erro ao executar winget: $($_.Exception.Message)"
        }
        return $Result
    }

    # Método 2: Instalador Customizado (MSI ou EXE)
    if ($InstPath) {
        $Result.TipoMetodo = "Instalador Customizado"
        $Result.Alvo = $InstPath

        if (-not (Test-Path $InstPath)) {
            $Result.Mensagem = "O instalador '$InstPath' não foi encontrado ou não está acessível."
            return $Result
        }

        $Extension = [System.IO.Path]::GetExtension($InstPath).ToLower()

        try {
            if ($Extension -eq ".msi") {
                $Arguments = if ($InstArgs) { $InstArgs } else { "/i `"$InstPath`" /qn /norestart" }
                $Process = Start-Process -FilePath "msiexec.exe" -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
            } else {
                # EXE
                $Arguments = if ($InstArgs) { $InstArgs } else { "/S /silent /quiet /norestart" }
                $Process = Start-Process -FilePath $InstPath -ArgumentList $Arguments -Wait -PassThru -NoNewWindow
            }

            $Result.CodigoSaida = $Process.ExitCode
            if ($Process.ExitCode -eq 0) {
                $Result.Sucesso = $true
                $Result.Mensagem = "Instalação concluída com êxito (Código 0)."
            } elseif ($Process.ExitCode -eq 3010) {
                $Result.Sucesso = $true
                $Result.Mensagem = "Instalação concluída com sucesso. Reinicialização necessária (Código 3010)."
            } else {
                $Result.Mensagem = "Instalador retornou código de saída diferente de zero: $($Process.ExitCode)."
            }
        } catch {
            $Result.Mensagem = "Falha ao disparar instalador: $($_.Exception.Message)"
        }
        return $Result
    }

    return $Result
}

$AllResults = [System.Collections.Generic.List[PSCustomObject]]::new()

foreach ($Target in $ComputerName) {
    Write-Host "Enviando comando para o computador: " -NoNewline
    Write-Host "$Target" -ForegroundColor Yellow

    try {
        if ($Target -eq "localhost" -or $Target -eq "127.0.0.1" -or $Target -eq $env:COMPUTERNAME) {
            $ExecResult = & $InstallScriptBlock $PackageId $InstallerPath $InstallerArgs
        } else {
            $InvokeParams = @{
                ComputerName = $Target
                ScriptBlock  = $InstallScriptBlock
                ArgumentList = @($PackageId, $InstallerPath, $InstallerArgs)
                ErrorAction  = "Stop"
            }
            if ($Credential) { $InvokeParams["Credential"] = $Credential }
            $ExecResult = Invoke-Command @InvokeParams
        }

        if ($ExecResult.Sucesso) {
            Write-Host "  -> [SUCESSO] $($ExecResult.Mensagem)" -ForegroundColor Green
        } else {
            Write-Host "  -> [FALHA] $($ExecResult.Mensagem)" -ForegroundColor Red
        }

        $AllResults.Add($ExecResult)
    }
    catch {
        Write-Host "  -> [ERRO DE CONEXÃO/WINRM]: $($_.Exception.Message)" -ForegroundColor Red
        $AllResults.Add([PSCustomObject]@{
            Computador  = $Target
            TipoMetodo  = if ($PackageId) { "Winget" } else { "CustomInstaller" }
            Alvo        = if ($PackageId) { $PackageId } else { $InstallerPath }
            Sucesso     = $false
            CodigoSaida = -1
            Mensagem    = "Erro de comunicação Remota: $($_.Exception.Message)"
        })
    }
    Write-Host ""
}

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Processo de instalação finalizado." -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan

return $AllResults
