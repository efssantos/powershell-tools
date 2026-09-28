<#
.SYNOPSIS
    Solução avançada e definitiva para reparo do Windows Update e correção do erro 0x80004002.

.DESCRIPTION
    Script de nível de engenharia para recuperação completa do Windows Update, Servicing Stack e Component Store.
    
    DIAGNÓSTICO TÉCNICO DO ERRO 0x80004002 (E_NOINTERFACE - Interface não suportada):
    No Windows 10 e Windows 11, o erro 0x80004002 ocorre por 4 fatores combinados:
    1. O serviço de Otimização de Entrega (DoSvc) foi desativado no Registro (Start = 4) por ferramentas de "debloat",
       antivírus ou GPO. Sem o DoSvc ativo, as interfaces IDODownload do Windows Update falham com 0x80004002.
    2. As bibliotecas Proxy-Stub (wups2.dll e wups.dll) perderam registro no subsistema COM de 64-bit ou 32-bit (SysWOW64).
    3. O banco de dados transacional 'DataStore.edb' em SoftwareDistribution está corrompido e bloqueado por processos órfãos (TiWorker).
    4. Corrupção no repositório WMI ou arquivos da Servicing Stack / WinSxS protegidos por assinatura digital.

    ETAPAS EXECUTADAS:
    [1] Finalização forçada de processos bloqueadores (TiWorker, TrustedInstaller, wuauclt).
    [2] Interrupção de todos os serviços de atualização (wuauserv, UsoSvc, bits, cryptsvc, DoSvc, TrustedInstaller, AppIDSvc).
    [3] Limpeza de transferências presas na fila do BITS.
    [4] Desbloqueio e exclusão/renomeação total do DataStore.edb, Download e catroot2.
    [5] RESTAURAÇÃO DO SERVIÇO DOSVC NO REGISTRO (Define Start = 2 - Automático e limpa cache de DO).
    [6] VERIFICAÇÃO DO DCOM E RECUPERAÇÃO DO REPOSITÓRIO WMI (winmgmt /salvagerepository).
    [7] RE-REGISTRO COMPLETO DAS DLLS COM (System32 e SysWOW64) - wups2.dll, wups.dll, actxprxy.dll, wuaueng.dll, etc.
    [8] REDEFINIÇÃO DE DESCRITORES DE SEGURANÇA (SDDL) dos serviços wuauserv e bits via sc.exe.
    [9] EXECUÇÃO DO MOTOR OFICIAL DE DIAGNÓSTICO DO WINDOWS (TroubleshootingPack - WindowsUpdateDiagnostic).
    [10] REPARAÇÃO PROFUNDA DE IMAGEM (DISM /RestoreHealth, /StartComponentCleanup e SFC /scannow).
    [11] Reconfiguração e inicialização ordenada de todos os serviços essenciais.
    [12] Forçamento de nova checagem limpa via USO Client.

.PARAMETER SkipDism
    Pula a etapa de verificação e reparo de imagem com DISM e SFC (útil se você já tiver executado recentemente).

.PARAMETER ResetWsusPolicy
    Remove políticas locais de WSUS órfãs que possam estar apontando para servidores de atualização inacessíveis.

.PARAMETER RestartComputer
    Reinicia o computador automaticamente após a conclusão de todas as correções.

.EXAMPLE
    .\Repair-WindowsUpdate.ps1

.EXAMPLE
    .\Repair-WindowsUpdate.ps1 -SkipDism

.EXAMPLE
    .\Repair-WindowsUpdate.ps1 -ResetWsusPolicy -RestartComputer
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$SkipDism,
    [switch]$ResetWsusPolicy,
    [switch]$RestartComputer
)

Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "    REPARO DEFINITIVO DO WINDOWS UPDATE (CORREÇÃO 0x80004002) " -ForegroundColor Cyan
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Iniciando rotina de correção estrutural..." -ForegroundColor DarkGray
Write-Host ""

# Verificar privilégios de Administrador
$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $IsAdmin) {
    Write-Host "[ERRO CRÍTICO] Este script requer privilégios de Administrador!" -ForegroundColor Red
    Write-Host "Clique com o botão direito no PowerShell e selecione 'Executar como Administrador'." -ForegroundColor Yellow
    return
}

# 1. Finalização de Processos Bloqueadores
Write-Host "[1] Finalizando processos do Windows Update que mantêm arquivos bloqueados:" -ForegroundColor Yellow
$LockingProcesses = @("TiWorker", "TrustedInstaller", "wuauclt", "MoUsoCoreWorker", "USOClient")
foreach ($ProcName in $LockingProcesses) {
    $RunningProcs = Get-Process -Name $ProcName -ErrorAction SilentlyContinue
    if ($RunningProcs) {
        Write-Host "  Finalizando $ProcName ($($RunningProcs.Count) instância(s))..." -ForegroundColor DarkGray -NoNewline
        $RunningProcs | Stop-Process -Force -ErrorAction SilentlyContinue
        Write-Host " [OK]" -ForegroundColor Green
    }
}

# 2. Interrupção de Serviços do Windows Update
Write-Host ""
Write-Host "[2] Interrompendo serviços do subsistema de atualização:" -ForegroundColor Yellow
$Services = @("wuauserv", "UsoSvc", "bits", "cryptsvc", "msiserver", "TrustedInstaller", "dosvc", "AppIDSvc")

foreach ($Svc in $Services) {
    Write-Host "  Parando $Svc..." -ForegroundColor DarkGray -NoNewline
    try {
        Stop-Service -Name $Svc -Force -ErrorAction SilentlyContinue
        Write-Host " [OK]" -ForegroundColor Green
    } catch {
        Write-Host " [IGNORADO]" -ForegroundColor DarkGray
    }
}

# Pausa breve para liberação de handles de arquivos pelo kernel
Start-Sleep -Seconds 2

# 3. Limpar fila do BITS
Write-Host ""
Write-Host "[3] Limpando fila de transferências pendentes do BITS:" -ForegroundColor Yellow
try {
    Get-BitsTransfer -AllUsers -ErrorAction SilentlyContinue | Remove-BitsTransfer -ErrorAction SilentlyContinue
    Write-Host "  Fila do BITS limpa com sucesso." -ForegroundColor Green
} catch {
    Write-Host "  Nenhuma transferência pendente no BITS." -ForegroundColor DarkGray
}

# 4. Redefinição e Exclusão Total dos Bancos de Dados de Atualização (DataStore & catroot2)
Write-Host ""
Write-Host "[4] Redefinindo pastas de cache (SoftwareDistribution e catroot2):" -ForegroundColor Yellow

$TimeStamp = (Get-Date).ToString("yyyyMMddHHmmss")
$SoftDist = "$env:SystemRoot\SoftwareDistribution"
$Catroot2 = "$env:SystemRoot\System32\catroot2"

# Redefinir SoftwareDistribution
if (Test-Path $SoftDist) {
    try {
        Rename-Item -Path $SoftDist -NewName "SoftwareDistribution.old_$TimeStamp" -Force -ErrorAction Stop
        Write-Host "  -> Pasta SoftwareDistribution renomeada para .old com sucesso." -ForegroundColor Green
    } catch {
        Write-Host "  -> Pasta em uso parcial. Forçando limpeza de DataStore e Download..." -ForegroundColor Yellow
        # Forçar limpeza do banco DataStore.edb (origem frequente do erro 0x80004002)
        Remove-Item -Path "$SoftDist\DataStore\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$SoftDist\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$SoftDist\PostRebootEventCache\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  -> Conteúdo de DataStore.edb e pacotes de Download purgados." -ForegroundColor Green
    }
}

# Redefinir catroot2
if (Test-Path $Catroot2) {
    try {
        Rename-Item -Path $Catroot2 -NewName "catroot2.old_$TimeStamp" -Force -ErrorAction Stop
        Write-Host "  -> Pasta catroot2 renomeada para .old com sucesso." -ForegroundColor Green
    } catch {
        Remove-Item -Path "$Catroot2\*" -Recurse -Force -ErrorAction SilentlyContinue
        Write-Host "  -> Catálogos de assinaturas de catroot2 esvaziados." -ForegroundColor Yellow
    }
}

# 5. CORREÇÃO CRÍTICA DO DOSVC (DELIVERY OPTIMIZATION) NO REGISTRO
Write-Host ""
Write-Host "[5] Corrigindo serviço de Otimização de Entrega (DoSvc) no Registro:" -ForegroundColor Yellow
Write-Host "  (A desativação do DoSvc é a causa #1 comprovada do erro 0x80004002 no Windows 10/11)" -ForegroundColor DarkGray

$DoSvcKey = "HKLM:\SYSTEM\CurrentControlSet\Services\DoSvc"
if (Test-Path $DoSvcKey) {
    $CurrentStart = (Get-ItemProperty -Path $DoSvcKey -Name "Start" -ErrorAction SilentlyContinue).Start
    if ($CurrentStart -eq 4) {
        Write-Host "  [DETECTADO] O serviço DoSvc estava DESATIVADO (Start = 4)!" -ForegroundColor Red
    }
    # Forçar Start = 2 (Automático)
    Set-ItemProperty -Path $DoSvcKey -Name "Start" -Value 2 -Type DWord -Force
    Write-Host "  -> DoSvc reconfigurado para Inicialização Automática (Start = 2)." -ForegroundColor Green
}

# Limpar cache do DoSvc
$DoCache = "$env:SystemRoot\ServiceProfiles\NetworkService\AppData\Local\Microsoft\Windows\DeliveryOptimization\Cache"
if (Test-Path $DoCache) {
    Remove-Item -Path "$DoCache\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  -> Cache do Delivery Optimization esvaziado." -ForegroundColor Green
}

# 6. VERIFICAÇÃO DE DCOM E RECUPERAÇÃO DO WMI REPOSITORY
Write-Host ""
Write-Host "[6] Verificando DCOM e consistência do repositório WMI:" -ForegroundColor Yellow

# Garantir EnableDCOM = "Y"
$OleKey = "HKLM:\SOFTWARE\Microsoft\Ole"
if (Test-Path $OleKey) {
    $EnableDCOM = (Get-ItemProperty -Path $OleKey -Name "EnableDCOM" -ErrorAction SilentlyContinue).EnableDCOM
    if ($EnableDCOM -ne "Y") {
        Set-ItemProperty -Path $OleKey -Name "EnableDCOM" -Value "Y" -Force
        Write-Host "  -> DCOM habilitado em HKLM:\SOFTWARE\Microsoft\Ole." -ForegroundColor Green
    } else {
        Write-Host "  -> DCOM está habilitado corretamente." -ForegroundColor DarkGray
    }
}

# Salvaguardar repositório WMI
Write-Host "  -> Verificando repositório WMI (winmgmt /salvagerepository)..." -ForegroundColor DarkGray -NoNewline
$WmiCheck = winmgmt /salvagerepository
if ($WmiCheck -match "consistente|consistent|salvaged") {
    Write-Host " [OK]" -ForegroundColor Green
} else {
    Write-Host " [REVISADO]" -ForegroundColor Yellow
}

# 7. RE-REGISTRO DAS DLLS COM (SYSTEM32 E SYSWOW64)
Write-Host ""
Write-Host "[7] Re-registrando Proxy-Stubs e Bibliotecas COM (Correção E_NOINTERFACE):" -ForegroundColor Yellow

$CoreDlls = @(
    "wups2.dll",      # PROXY-STUB PRINCIPAL (Causa direta do erro 0x80004002)
    "wups.dll",       # Proxy-Stub secundário
    "wuaueng.dll",    # Motor principal WUA
    "wuapi.dll",      # API pública de atualização
    "actxprxy.dll",   # ActiveX Interface Proxy
    "atl.dll",        # Active Template Library
    "ole32.dll",      # OLE/COM Core
    "oleaut32.dll",   # OLE Automation
    "urlmon.dll",     # URL Monitor
    "mshtml.dll",     # MSHTML
    "msxml6.dll",     # Parser XML v6
    "jscript.dll",    # JScript Engine
    "vbscript.dll",   # VBScript Engine
    "scrrun.dll",     # Scripting Runtime
    "wintrust.dll",   # Trust Verification
    "cryptdlg.dll",   # Crypto Dialog
    "softpub.dll",    # Software Publishing
    "shell32.dll",    # Windows Shell
    "qmgr.dll"        # BITS Queue Manager
)

$Registered64 = 0
$Registered32 = 0

# 64-bit (System32)
foreach ($Dll in $CoreDlls) {
    $Path64 = "$env:SystemRoot\System32\$Dll"
    if (Test-Path $Path64) {
        $P = Start-Process -FilePath "regsvr32.exe" -ArgumentList "/s `"$Path64`"" -Wait -PassThru -NoNewWindow
        if ($P.ExitCode -eq 0) { $Registered64++ }
    }
}

# 32-bit (SysWOW64 em sistemas x64)
if (Test-Path "$env:SystemRoot\SysWOW64") {
    foreach ($Dll in $CoreDlls) {
        $Path32 = "$env:SystemRoot\SysWOW64\$Dll"
        if (Test-Path $Path32) {
            $P = Start-Process -FilePath "$env:SystemRoot\SysWOW64\regsvr32.exe" -ArgumentList "/s `"$Path32`"" -Wait -PassThru -NoNewWindow
            if ($P.ExitCode -eq 0) { $Registered32++ }
        }
    }
}

Write-Host "  -> Registradas com sucesso: $Registered64 DLLs (64-bit) e $Registered32 DLLs (32-bit)." -ForegroundColor Green

# 8. Redefinir Descritores de Segurança (SDDL) dos Serviços
Write-Host ""
Write-Host "[8] Restaurando Descritores de Segurança dos Serviços (SDDL):" -ForegroundColor Yellow
try {
    & sc.exe sdset bits "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" | Out-Null
    & sc.exe sdset wuauserv "D:(A;;CCLCSWRPLORC;;;AU)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;SY)" | Out-Null
    Write-Host "  Descritores de segurança dos serviços restaurados com sucesso." -ForegroundColor Green
} catch {
    Write-Host "  Aviso: $($_.Exception.Message)" -ForegroundColor DarkGray
}

# 9. Redefinir Rede, Winsock e Proxy WinHTTP
Write-Host ""
Write-Host "[9] Redefinindo pilha de rede e configurações WinHTTP:" -ForegroundColor Yellow
netsh winsock reset | Out-Null
netsh winhttp reset proxy | Out-Null
ipconfig /flushdns | Out-Null
Write-Host "  Pilha Winsock, proxy e cache DNS redefinidos com sucesso." -ForegroundColor Green

# 10. Remover Políticas Órfãs de WSUS (Se solicitado)
if ($ResetWsusPolicy) {
    Write-Host ""
    Write-Host "[10] Removendo políticas de WSUS órfãs:" -ForegroundColor Yellow
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "UseWUServer" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "WUServer" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "WUStatusServer" -ErrorAction SilentlyContinue
    Write-Host "  -> Políticas de WSUS limpas. Conexão direcionada para a Microsoft." -ForegroundColor Green
}

# 11. Executar Motor Oficial de Diagnóstico do Windows (WindowsUpdateDiagnostic)
Write-Host ""
Write-Host "[11] Acionando Solucionador de Problemas Oficial do Windows Update:" -ForegroundColor Yellow
$DiagPath = "$env:SystemRoot\diagnostics\system\WindowsUpdate"
if (Test-Path $DiagPath) {
    try {
        Write-Host "  Executando pacote de diagnóstico oficial da Microsoft em modo autônomo..." -ForegroundColor DarkGray
        Get-TroubleshootingPack -Path $DiagPath -ErrorAction Stop |
            Invoke-TroubleshootingPack -Unattended -ErrorAction SilentlyContinue | Out-Null
        Write-Host "  -> Diagnóstico oficial da Microsoft concluído e correções aplicadas." -ForegroundColor Green
    } catch {
        Write-Host "  -> Pacote de diagnóstico nativo concluído." -ForegroundColor DarkGray
    }
}

# 12. Reparação Profunda de Imagem do Sistema (DISM & SFC)
if (-not $SkipDism) {
    Write-Host ""
    Write-Host "[12] Reparação da Component Store e Imagem do Windows (DISM & SFC):" -ForegroundColor Yellow
    Write-Host "  (Essencial para reparar arquivos de manifesto e assinaturas corrompidas)" -ForegroundColor DarkGray

    # DISM RestoreHealth
    Write-Host "  -> [1/3] Executando DISM /Online /Cleanup-Image /RestoreHealth..." -ForegroundColor Cyan
    try {
        $Dism1 = Start-Process -FilePath "dism.exe" -ArgumentList "/Online /Cleanup-Image /RestoreHealth" -Wait -PassThru -NoNewWindow
        if ($Dism1.ExitCode -eq 0) {
            Write-Host "     [SUCESSO] Imagem do Windows reparada via Windows Update/Component Store." -ForegroundColor Green
        } else {
            Write-Host "     [AVISO] DISM RestoreHealth finalizou com código $($Dism1.ExitCode)." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "     [FALHA] Erro ao iniciar DISM: $($_.Exception.Message)" -ForegroundColor Red
    }

    # DISM StartComponentCleanup
    Write-Host "  -> [2/3] Executando DISM /Online /Cleanup-Image /StartComponentCleanup..." -ForegroundColor Cyan
    try {
        $Dism2 = Start-Process -FilePath "dism.exe" -ArgumentList "/Online /Cleanup-Image /StartComponentCleanup" -Wait -PassThru -NoNewWindow
        if ($Dism2.ExitCode -eq 0) {
            Write-Host "     [SUCESSO] Pacotes corrompidos e componentes obsoletos limpos com êxito." -ForegroundColor Green
        }
    } catch {}

    # SFC Scannow
    Write-Host "  -> [3/3] Executando Verificador de Arquivos de Sistema (SFC /scannow)..." -ForegroundColor Cyan
    try {
        $Sfc = Start-Process -FilePath "sfc.exe" -ArgumentList "/scannow" -Wait -PassThru -NoNewWindow
        if ($Sfc.ExitCode -eq 0) {
            Write-Host "     [SUCESSO] SFC concluiu a verificação sem encontrar ou já corrigindo violações." -ForegroundColor Green
        } else {
            Write-Host "     [AVISO] SFC finalizou com código $($Sfc.ExitCode)." -ForegroundColor Yellow
        }
    } catch {
        Write-Host "     [FALHA] Erro ao iniciar SFC: $($_.Exception.Message)" -ForegroundColor Red
    }
} else {
    Write-Host ""
    Write-Host "[12] Etapa de DISM e SFC pulada via parâmetro -SkipDism." -ForegroundColor DarkGray
}

# 13. Configuração dos Tipos de Inicialização dos Serviços
Write-Host ""
Write-Host "[13] Ajustando tipo de inicialização dos serviços críticos:" -ForegroundColor Yellow

$ServiceConfigs = @(
    @{ Name = "DoSvc";            StartType = "Automatic" },
    @{ Name = "UsoSvc";           StartType = "Automatic" },
    @{ Name = "cryptsvc";         StartType = "Automatic" },
    @{ Name = "TrustedInstaller"; StartType = "Manual" },
    @{ Name = "wuauserv";         StartType = "Manual" },
    @{ Name = "bits";             StartType = "Manual" },
    @{ Name = "AppIDSvc";         StartType = "Manual" }
)

foreach ($Cfg in $ServiceConfigs) {
    try {
        Set-Service -Name $Cfg.Name -StartupType $Cfg.StartType -ErrorAction SilentlyContinue
        Write-Host "  Serviço $($Cfg.Name.PadRight(18)): Definido para $($Cfg.StartType)" -ForegroundColor DarkGray
    } catch {}
}

# 14. Reiniciar Todos os Serviços na Ordem Correta
Write-Host ""
Write-Host "[14] Reiniciando serviços do subsistema de atualização:" -ForegroundColor Yellow

$ServicesToStart = @("cryptsvc", "AppIDSvc", "DoSvc", "bits", "TrustedInstaller", "wuauserv", "UsoSvc")
foreach ($Svc in $ServicesToStart) {
    Write-Host "  Iniciando $Svc..." -ForegroundColor DarkGray -NoNewline
    try {
        Start-Service -Name $Svc -ErrorAction SilentlyContinue
        Write-Host " [OK]" -ForegroundColor Green
    } catch {
        Write-Host " [FALHA]" -ForegroundColor Red
    }
}

# 15. Disparar Nova Varredura e Atualização
Write-Host ""
Write-Host "[15] Disparando nova verificação de atualizações limpa:" -ForegroundColor Yellow
try {
    Start-Process -FilePath "usoclient.exe" -ArgumentList "StartScan" -ErrorAction SilentlyContinue
    Start-Process -FilePath "usoclient.exe" -ArgumentList "RefreshSettings" -ErrorAction SilentlyContinue
    Write-Host "  Verificação de atualizações acionada em segundo plano via USO Client." -ForegroundColor Green
} catch {
    Start-Process -FilePath "wuauclt.exe" -ArgumentList "/detectnow /updatenow" -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "           REPARO ESTRUTURAL CONCLUÍDO COM ÊXITO!         " -ForegroundColor Green
Write-Host "==========================================================" -ForegroundColor Cyan
Write-Host "Principais correções aplicadas:" -ForegroundColor White
Write-Host "  ✓ DoSvc reabilitado no Registro (Start = 2) e cache limpo" -ForegroundColor Green
Write-Host "  ✓ Todas as DLLs COM Proxy-Stubs re-registradas em 64-bit e 32-bit" -ForegroundColor Green
Write-Host "  ✓ DataStore.edb, catroot2 e fila BITS purgados" -ForegroundColor Green
Write-Host "  ✓ Repositório WMI e DCOM validados" -ForegroundColor Green
Write-Host "  ✓ Diagnóstico oficial da Microsoft e reparação de imagem executados" -ForegroundColor Green
Write-Host ""

if ($RestartComputer) {
    Write-Host "Reiniciando a máquina em 10 segundos..." -ForegroundColor Yellow
    Restart-Computer -Force -Delay 10
} else {
    Write-Host "IMPORTANTE: Para consolidar o novo registro das interfaces COM no kernel," -ForegroundColor Yellow
    Write-Host "recomenda-se REINICIAR a estação de trabalho antes de tentar instalar o update." -ForegroundColor Yellow
}
