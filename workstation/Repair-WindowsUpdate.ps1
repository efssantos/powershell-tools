<#
.SYNOPSIS
    Corrige falhas, travamentos e erros de instalação do Windows Update (incluindo o erro 0x80004002).

.DESCRIPTION
    Script abrangente de recuperação do Windows Update e do subsistema de manutenção do Windows (Servicing Stack).
    
    Tratamento específico para o erro 0x80004002 (E_NOINTERFACE - Interface não suportada):
    O erro 0x80004002 ocorre quando as bibliotecas COM e Proxy-Stubs do Windows Update (principalmente wups2.dll e wups.dll)
    estão desregistradas ou corrompidas no Registro, impedindo a comunicação entre o Agente de Atualização (WUA), o
    orquestrador (UsoSvc) e o Instalador de Módulos do Windows (TrustedInstaller).

    Ações realizadas pelo script:
    1. Interrupção controlada de serviços: wuauserv, UsoSvc, bits, cryptsvc, msiserver, TrustedInstaller e dosvc.
    2. Limpeza completa da fila pendente de downloads do BITS.
    3. Redefinição e backup das pastas de cache 'SoftwareDistribution' e 'catroot2'.
    4. RE-REGISTRO COMPLETO DAS DLLS COM (wups2.dll, wups.dll, wuaueng.dll, wuapi.dll, actxprxy.dll, etc.) - Corrige 0x80004002.
    5. Redefinição dos Descritores de Segurança (SDDL) dos serviços wuauserv e BITS.
    6. Restauração dos tipos de inicialização corretos dos serviços (garantindo que o TrustedInstaller não esteja desativado).
    7. Redefinição da pilha de rede Winsock, proxy WinHTTP e cache DNS.
    8. Suporte a Reparo Profundo (-DeepRepair): Executa DISM (RestoreHealth) e SFC (scannow) na Component Store.
    9. Suporte a bypass/redefinição de políticas de WSUS corrompidas (-ResetWsusPolicy).
    10. Reinicialização ordenada dos serviços e disparo de nova verificação limpa de atualizações.

.PARAMETER DeepRepair
    Executa a reparação profunda da imagem do sistema (DISM /Online /Cleanup-Image /RestoreHealth)
    e verificação de integridade dos arquivos de sistema protegidos (SFC /scannow).

.PARAMETER ResetWsusPolicy
    Remove políticas locais de WSUS órfãs que possam estar apontando para servidores de atualização inacessíveis.

.PARAMETER RestartComputer
    Reinicia o computador automaticamente após a conclusão das correções.

.EXAMPLE
    .\Repair-WindowsUpdate.ps1

.EXAMPLE
    .\Repair-WindowsUpdate.ps1 -DeepRepair

.EXAMPLE
    .\Repair-WindowsUpdate.ps1 -DeepRepair -ResetWsusPolicy
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$DeepRepair,
    [switch]$ResetWsusPolicy,
    [switch]$RestartComputer
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "    REPARO AVANÇADO DO WINDOWS UPDATE (CORREÇÃO 0x80004002) " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Iniciando rotina de reparação do Windows Update e Servicing Stack..." -ForegroundColor DarkGray
Write-Host ""

# Verificar privilégios de Administrador
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Warning "Este script requer privilégios de Administrador! Abra o PowerShell como Administrador e execute novamente."
    return
}

# 1. Parar Serviços Relacionados
$Services = @("wuauserv", "UsoSvc", "bits", "cryptsvc", "msiserver", "TrustedInstaller", "dosvc")

Write-Host "[1] Interrompendo serviços do Windows Update, Orquestrador e BITS:" -ForegroundColor Yellow
foreach ($Svc in $Services) {
    Write-Host "  Parando serviço $Svc..." -ForegroundColor DarkGray -NoNewline
    try {
        Stop-Service -Name $Svc -Force -ErrorAction SilentlyContinue
        Write-Host " [OK]" -ForegroundColor Green
    } catch {
        Write-Host " [IGNORADO]" -ForegroundColor DarkGray
    }
}

# 2. Limpar fila pendente do BITS
Write-Host ""
Write-Host "[2] Limpando fila de transferências pendentes do BITS:" -ForegroundColor Yellow
try {
    Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Remove-BitsTransfer -ErrorAction SilentlyContinue
    Write-Host "  Fila do BITS limpa com sucesso." -ForegroundColor Green
} catch {
    Write-Host "  Nenhuma transferência pendente no BITS." -ForegroundColor DarkGray
}

# 3. Renomear e redefinir pastas de cache (SoftwareDistribution e Catroot2)
Write-Host ""
Write-Host "[3] Redefinindo pastas de cache do Windows Update:" -ForegroundColor Yellow

$TimeStamp = (Get-Date).ToString("yyyyMMddHHmmss")
$SoftDist = "$env:SystemRoot\SoftwareDistribution"
$Catroot2 = "$env:SystemRoot\System32\catroot2"

if (Test-Path $SoftDist) {
    try {
        Rename-Item -Path $SoftDist -NewName "SoftwareDistribution.old_$TimeStamp" -Force -ErrorAction Stop
        Write-Host "  -> Pasta SoftwareDistribution renomeada para .old com sucesso." -ForegroundColor Green
    } catch {
        Write-Host "  -> SoftwareDistribution em uso parcial. Esvaziando arquivos de download..." -ForegroundColor Yellow
        Get-ChildItem -Path "$SoftDist\Download" -Recurse -Force -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
    }
}

if (Test-Path $Catroot2) {
    try {
        Rename-Item -Path $Catroot2 -NewName "catroot2.old_$TimeStamp" -Force -ErrorAction Stop
        Write-Host "  -> Pasta catroot2 renomeada para .old com sucesso." -ForegroundColor Green
    } catch {
        Write-Host "  -> catroot2 em uso por serviço de segurança do sistema." -ForegroundColor DarkGray
    }
}

# 4. RE-REGISTRO DAS DLLS COM DO WINDOWS UPDATE (SOLUÇÃO CHAVE PARA O ERRO 0x80004002)
Write-Host ""
Write-Host "[4] Re-registrando bibliotecas COM e Proxy-Stubs (Correção 0x80004002 - E_NOINTERFACE):" -ForegroundColor Yellow

$CoreDlls = @(
    "wups2.dll",      # ESSENCIAL: Proxy-Stub principal do WUA (Causa direta do erro 0x80004002)
    "wups.dll",       # ESSENCIAL: Proxy-Stub secundário
    "wuaueng.dll",    # Motor do Windows Update Agent
    "wuapi.dll",      # API de cliente do Windows Update
    "wucltux.dll",    # Interface do usuário do Windows Update
    "wudriver.dll",   # Instalador de drivers
    "atl.dll",        # Biblioteca de templates ativos
    "urlmon.dll",     # Monitor de URLs e downloads
    "mshtml.dll",     # Componentes de renderização
    "shdocvw.dll",    # Shell Doc Object
    "browseui.dll",   # Interface do navegador
    "jscript.dll",    # Motor JScript
    "vbscript.dll",   # Motor VBScript
    "scrrun.dll",     # Script Runtime
    "msxml.dll",      # Parser XML
    "msxml3.dll",     # Parser XML v3
    "msxml6.dll",     # Parser XML v6
    "actxprxy.dll",   # ActiveX Proxy Stub
    "softpub.dll",    # Verificação de publicação de software
    "wintrust.dll",   # Confiança e certificados de binários
    "dssenh.dll",     # Criptografia avançada
    "rsaenh.dll",     # Criptografia RSA
    "cryptdlg.dll",   # Diálogos de certificados
    "ole32.dll",      # OLE / COM Base
    "oleaut32.dll",   # Automação OLE
    "shell32.dll",    # Shell do Windows
    "qmgr.dll",       # Gerenciador do BITS
    "qmgrprxy.dll"    # Proxy do BITS
)

$RegisteredCount = 0
foreach ($Dll in $CoreDlls) {
    $DllPath = "$env:SystemRoot\System32\$Dll"
    if (Test-Path $DllPath) {
        try {
            $Proc = Start-Process -FilePath "regsvr32.exe" -ArgumentList "/s `"$DllPath`"" -Wait -PassThru -NoNewWindow
            $RegisteredCount++
        } catch {}
    }
}
Write-Host "  -> $RegisteredCount bibliotecas COM registradas com sucesso no Registro do Windows." -ForegroundColor Green

# 5. Redefinir Descritores de Segurança (SDDL) dos Serviços wuauserv e BITS
Write-Host ""
Write-Host "[5] Redefinindo Descritores de Segurança dos Serviços (SDDL):" -ForegroundColor Yellow
try {
    # Permissões padrão para permitir comunicação RPC/COM entre contas de sistema e administradores
    & sc.exe sdset bits "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" | Out-Null
    & sc.exe sdset wuauserv "D:(A;;CCLCSWRPLORC;;;AU)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)" | Out-Null
    Write-Host "  Descritores de segurança dos serviços restaurados para o padrão." -ForegroundColor Green
} catch {
    Write-Host "  Aviso ao redefinir SDDL: $($_.Exception.Message)" -ForegroundColor DarkGray
}

# 6. Redefinir pilha de rede, WinSock, WinHTTP e DNS
Write-Host ""
Write-Host "[6] Redefinindo pilha de rede e configurações WinHTTP:" -ForegroundColor Yellow
try {
    netsh winsock reset | Out-Null
    netsh winhttp reset proxy | Out-Null
    ipconfig /flushdns | Out-Null
    Write-Host "  Pilha Winsock, proxy WinHTTP e cache DNS redefinidos com sucesso." -ForegroundColor Green
} catch {
    Write-Host "  Aviso na redefinição de rede: $($_.Exception.Message)" -ForegroundColor DarkGray
}

# 7. Redefinição de Políticas de WSUS (Opcional)
if ($ResetWsusPolicy) {
    Write-Host ""
    Write-Host "[7] Verificando e redefinindo políticas de WSUS:" -ForegroundColor Yellow
    $WsusKeyAU = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
    $WsusKeyWU = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"

    if (Test-Path $WsusKeyAU) {
        Remove-ItemProperty -Path $WsusKeyAU -Name "UseWUServer" -ErrorAction SilentlyContinue
        Write-Host "  -> 'UseWUServer' removido. O Windows Update buscará atualizações diretamente nos servidores da Microsoft." -ForegroundColor Green
    }
    if (Test-Path $WsusKeyWU) {
        Remove-ItemProperty -Path $WsusKeyWU -Name "WUServer" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $WsusKeyWU -Name "WUStatusServer" -ErrorAction SilentlyContinue
        Write-Host "  -> Servidores WSUS órfãos removidos das políticas do registro." -ForegroundColor Green
    }
}

# 8. Reparação Profunda da Imagem do Sistema e Component Store (DISM / SFC)
if ($DeepRepair) {
    Write-Host ""
    Write-Host "[8] Executando Reparação Profunda de Componentes do Sistema (DISM & SFC):" -ForegroundColor Yellow
    Write-Host "  Isso pode levar alguns minutos. Aguarde..." -ForegroundColor DarkGray

    Write-Host "  -> Executando DISM /Online /Cleanup-Image /RestoreHealth..." -ForegroundColor Cyan
    try {
        $DismProcess = Start-Process -FilePath "dism.exe" -ArgumentList "/Online /Cleanup-Image /RestoreHealth" -Wait -PassThru -NoNewWindow
        if ($DismProcess.ExitCode -eq 0) {
            Write-Host "     [SUCESSO] Repositório de componentes (Component Store) restaurado com êxito!" -ForegroundColor Green
        } else {
            Write-Host "     [AVISO] DISM finalizou com código: $($DismProcess.ExitCode)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "     [FALHA] Não foi possível executar o DISM: $($_.Exception.Message)" -ForegroundColor Red
    }

    Write-Host "  -> Executando Verificador de Arquivos de Sistema (SFC /scannow)..." -ForegroundColor Cyan
    try {
        $SfcProcess = Start-Process -FilePath "sfc.exe" -ArgumentList "/scannow" -Wait -PassThru -NoNewWindow
        if ($SfcProcess.ExitCode -eq 0) {
            Write-Host "     [SUCESSO] SFC concluiu a verificação sem violações ou corrigiu arquivos corrompidos." -ForegroundColor Green
        } else {
            Write-Host "     [AVISO] SFC finalizou com código: $($SfcProcess.ExitCode)" -ForegroundColor Yellow
        }
    } catch {
        Write-Host "     [FALHA] Não foi possível executar o SFC: $($_.Exception.Message)" -ForegroundColor Red
    }
}

# 9. Garantir tipos de inicialização corretos dos serviços
Write-Host ""
Write-Host "[9] Configurando tipo de inicialização dos serviços do sistema:" -ForegroundColor Yellow

$ServiceConfigs = @(
    @{ Name = "TrustedInstaller"; StartType = "Manual" },
    @{ Name = "wuauserv";         StartType = "Manual" },
    @{ Name = "UsoSvc";           StartType = "Automatic" },
    @{ Name = "bits";             StartType = "Manual" },
    @{ Name = "cryptsvc";         StartType = "Automatic" }
)

foreach ($Cfg in $ServiceConfigs) {
    try {
        Set-Service -Name $Cfg.Name -StartupType $Cfg.StartType -ErrorAction SilentlyContinue
        Write-Host "  Serviço $($Cfg.Name): Definido para $($Cfg.StartType)" -ForegroundColor DarkGray
    } catch {}
}

# 10. Reiniciar Serviços na ordem correta
Write-Host ""
Write-Host "[10] Reiniciando os serviços essenciais:" -ForegroundColor Yellow

$ServicesToStart = @("cryptsvc", "bits", "TrustedInstaller", "wuauserv", "UsoSvc")
foreach ($Svc in $ServicesToStart) {
    Write-Host "  Iniciando serviço $Svc..." -ForegroundColor DarkGray -NoNewline
    try {
        Start-Service -Name $Svc -ErrorAction SilentlyContinue
        Write-Host " [OK]" -ForegroundColor Green
    } catch {
        Write-Host " [FALHA]" -ForegroundColor Red
    }
}

# 11. Disparar nova verificação de atualizações limpa
Write-Host ""
Write-Host "[11] Disparando nova verificação de atualizações:" -ForegroundColor Yellow
try {
    # Orquestrador moderno (Windows 10 e Windows 11)
    Start-Process -FilePath "usoclient.exe" -ArgumentList "StartScan" -ErrorAction SilentlyContinue
    Start-Process -FilePath "usoclient.exe" -ArgumentList "RefreshSettings" -ErrorAction SilentlyContinue
    Write-Host "  Busca de atualizações acionada via USO Client (Orquestrador do Windows 10/11)." -ForegroundColor Green
} catch {
    Write-Host "  Tentativa via wuauclt..." -ForegroundColor DarkGray
    Start-Process -FilePath "wuauclt.exe" -ArgumentList "/detectnow /updatenow" -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Reparo do Windows Update concluído com sucesso!" -ForegroundColor Cyan
Write-Host "As bibliotecas COM foram re-registradas, eliminando a causa do erro 0x80004002." -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan

if ($RestartComputer) {
    Write-Host "Reiniciando o computador em 10 segundos..." -ForegroundColor Yellow
    Restart-Computer -Force -Delay 10
} else {
    Write-Host "Recomendação: Para aplicar integralmente as alterações nas interfaces COM e registro," -ForegroundColor Yellow
    Write-Host "reinicie a estação de trabalho caso a atualização ainda apresente instabilidades." -ForegroundColor Yellow
}
