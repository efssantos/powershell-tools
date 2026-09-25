# 🛠️ PowerShell Tools - Administração de Servidores e Infraestrutura de TI

Este repositório contém um conjunto de scripts e utilitários em PowerShell desenvolvidos para otimizar e facilitar a rotina diária de administradores de sistemas, analistas de suporte e engenheiros de infraestrutura.

Os scripts estão organizados por categorias em diretórios específicos, seguindo boas práticas de modularidade, tratamento de exceções, saída visual clara (com destaque de status por cores) e suporte a execução com parâmetros customizados ou valores padrão.

---

## 📁 Estrutura de Diretórios

```plaintext
powershell-tools/
├── active directory/
│   ├── Audit-LocalAdministrators.ps1    # Auditoria de membros do grupo local de Administradores
│   └── Audit-LockedAccounts.ps1         # Consulta e desbloqueio de contas de usuário no AD
├── maintenance/
│   ├── Clean-ServerTempFiles.ps1        # Limpeza aprofundada de arquivos temporários e caches
│   └── Find-LargeFiles.ps1              # Localizador rápido de grandes arquivos em disco
├── network/
│   ├── Get-NetworkDiagnostics.ps1       # Diagnóstico de interfaces, IP, rotas e testes DNS/Internet
│   └── Test-PortConnectivity.ps1        # Teste de conectividade e portas TCP com latência
├── security/
│   └── Get-RecentEventErrors.ps1        # Varredura e sumarização de erros nos Logs de Eventos
├── system/
│   ├── Get-ServerHealthReport.ps1       # Health check do servidor (CPU, RAM, Discos, Top Processos, HTML)
│   └── Manage-CriticalServices.ps1      # Monitoramento e recuperação automática de serviços essenciais
├── virtual machine/
│   ├── Get-HyperVSummary.ps1            # Resumo de VMs Hyper-V (Estado, CPU, RAM, Checkpoints)
│   └── VirtualMachineTemplate.ps1       # Provisionamento de nova VM a partir de template VHDX
├── workstation/
│   ├── Get-WorkstationDiagnostics.ps1   # Diagnóstico rápido de hardware, SMART, bateria, BSOD e pendências
│   ├── Install-RemoteSoftware.ps1       # Instalação silenciosa e remota de softwares via Winget ou MSI/EXE
│   ├── Optimize-WorkstationPerformance.ps1 # Otimização de desempenho, limpeza de navegadores, TRIM e inicialização
│   └── Repair-WindowsUpdate.ps1         # Correção e redefinição de componentes travados do Windows Update
├── CleanTempFiles.ps1                   # Script legado de limpeza rápida da pasta Temp do usuário
└── README.md
```

---

## 🚀 Guia dos Scripts por Categoria

### 🌐 1. Rede (`network/`)

* **[`Test-PortConnectivity.ps1`](./network/Test-PortConnectivity.ps1)**
  * **Finalidade:** Testa a conectividade TCP para portas essenciais (RDP, SMB, HTTP, HTTPS, SSH, DNS, etc.) ou portas personalizadas em servidores e IPs.
  * **Destaque:** Usa sockets .NET assíncronos de alta performance com medição de latência em milissegundos.
  * **Exemplo de uso:**
    ```powershell
    .\network\Test-PortConnectivity.ps1 -Destination "192.168.1.50" -Ports 3389, 445, 80
    .\network\Test-PortConnectivity.ps1 -Destination "srv-sql-01", "srv-app-01" -Ports 1433, 443
    ```

* **[`Get-NetworkDiagnostics.ps1`](./network/Get-NetworkDiagnostics.ps1)**
  * **Finalidade:** Fornece um panorama imediato da configuração de rede do host.
  * **Destaque:** Lista adaptadores ativos, endereços IPv4, máscaras, gateways, DNS configurados, velocidade de link, testa o ping até o gateway e valida saída para a Internet e resolução externa.
  * **Exemplo de uso:**
    ```powershell
    .\network\Get-NetworkDiagnostics.ps1
    ```

---

### 💻 2. Sistema Operacional & Recursos (`system/`)

* **[`Get-ServerHealthReport.ps1`](./system/Get-ServerHealthReport.ps1)**
  * **Finalidade:** Relatório completo de integridade e capacidade do servidor Windows.
  * **Destaque:** Exibe versão do SO, Uptime (tempo de atividade), uso atual de CPU e contagem de núcleos, consumo detalhado de memória RAM, status de cada volume de disco com alertas visuais (Alerta se < 25% livre, Crítico se < 15% livre) e top 5 processos maiores consumidores.
  * **Recurso extra:** Suporte a geração de relatório HTML profissional (`-ExportHtml`).
  * **Exemplo de uso:**
    ```powershell
    .\system\Get-ServerHealthReport.ps1
    .\system\Get-ServerHealthReport.ps1 -ExportHtml
    ```

* **[`Manage-CriticalServices.ps1`](./system/Manage-CriticalServices.ps1)**
  * **Finalidade:** Audita o status de serviços fundamentais de infraestrutura (RDP, WinRM, Spooler, W32Time, Windows Update, Firewall, LanmanServer).
  * **Destaque:** Identifica serviços configurados como Inicialização Automática que estão caídos e permite reiniciar com o switch `-AutoRestart`.
  * **Exemplo de uso:**
    ```powershell
    .\system\Manage-CriticalServices.ps1
    .\system\Manage-CriticalServices.ps1 -AutoRestart
    ```

---

### 🧹 3. Manutenção & Armazenamento (`maintenance/`)

* **[`Clean-ServerTempFiles.ps1`](./maintenance/Clean-ServerTempFiles.ps1)**
  * **Finalidade:** Limpeza aprofundada e segura de arquivos temporários em servidores.
  * **Destaque:** Limpa Windows Temp, pastas Temp de todos os perfis de usuários em `C:\Users`, cache do Windows Update (`SoftwareDistribution\Download`), dumps de erro de programas, lixeira e logs antigos do IIS (opcional). Calcula e exibe a quantidade exata de espaço liberado em MB/GB.
  * **Exemplo de uso:**
    ```powershell
    .\maintenance\Clean-ServerTempFiles.ps1 -DaysOld 3
    .\maintenance\Clean-ServerTempFiles.ps1 -DaysOld 7 -CleanUpdateCache -CleanIISLogs
    ```

* **[`Find-LargeFiles.ps1`](./maintenance/Find-LargeFiles.ps1)**
  * **Finalidade:** Encontra rapidamente arquivos volumosos que estão lotando discos de servidores (arquivos .vmdk/.vhdx esquecidos, dumps de banco de dados .bak, logs gigantescos .log, ISOs).
  * **Destaque:** Permite definir tamanho mínimo em MB, ordenar pelos maiores e exportar os resultados para CSV.
  * **Exemplo de uso:**
    ```powershell
    .\maintenance\Find-LargeFiles.ps1 -Path "C:\" -MinSizeMB 500 -Top 20
    .\maintenance\Find-LargeFiles.ps1 -Path "D:\Backups" -MinSizeMB 1024 -ExportCsv "C:\Temp\relatorio_arquivos.csv"
    ```

---

### 👥 4. Active Directory & Acessos (`active directory/`)

* **[`Audit-LockedAccounts.ps1`](./active directory/Audit-LockedAccounts.ps1)**
  * **Finalidade:** Identifica contas de usuários bloqueadas no Active Directory.
  * **Destaque:** Mostra quantidade de tentativas de senha incorreta, data/hora da última falha e possibilita o desbloqueio em massa ou individual com `-UnlockAll`.
  * **Exemplo de uso:**
    ```powershell
    .\active directory\Audit-LockedAccounts.ps1
    .\active directory\Audit-LockedAccounts.ps1 -UnlockAll
    .\active directory\Audit-LockedAccounts.ps1 -SpecificUser "usuario.teste"
    ```

* **[`Audit-LocalAdministrators.ps1`](./active directory/Audit-LocalAdministrators.ps1)**
  * **Finalidade:** Audita membros do grupo local `Administrators` da máquina/servidor.
  * **Destaque:** Classifica se o membro é Conta Local, Conta de Domínio ou Grupo, e identifica **SIDs órfãos** (contas deletadas do domínio que ainda constam no grupo local).
  * **Exemplo de uso:**
    ```powershell
    .\active directory\Audit-LocalAdministrators.ps1
    .\active directory\Audit-LocalAdministrators.ps1 -ComputerName "SRV-APP-02"
    ```

---

### 🛡️ 5. Segurança & Diagnósticos (`security/`)

* **[`Get-RecentEventErrors.ps1`](./security/Get-RecentEventErrors.ps1)**
  * **Finalidade:** Coleta e resume erros críticos e falhas nos canais `System` e `Application` do Visualizador de Eventos (Event Viewer).
  * **Destaque:** Agrupa erros por frequência de origem e Event ID nas últimas X horas, permitindo diagnóstico imediato sem necessidade de navegar manualmente pela interface gráfica pesada do Event Viewer.
  * **Exemplo de uso:**
    ```powershell
    .\security\Get-RecentEventErrors.ps1
    .\security\Get-RecentEventErrors.ps1 -Hours 48 -MaxEvents 50
    ```

---

### 🖥️ 6. Virtualização (`virtual machine/`)

* **[`Get-HyperVSummary.ps1`](./virtual machine/Get-HyperVSummary.ps1)**
  * **Finalidade:** Resumo de saúde e inventário das máquinas virtuais no Hyper-V.
  * **Destaque:** Mostra estado (Running/Off), consumo de CPU, alocação de memória RAM e alerta para máquinas com checkpoints/snapshots ativos (que degradam performance e consomem disco físico).
  * **Exemplo de uso:**
    ```powershell
    .\virtual machine\Get-HyperVSummary.ps1
    .\virtual machine\Get-HyperVSummary.ps1 -VMName "SRV-WEB*"
    ```

* **[`VirtualMachineTemplate.ps1`](./virtual machine/VirtualMachineTemplate.ps1)**
  * **Finalidade:** Provisionamento automatizado de nova máquina virtual a partir de um disco template base (.vhdx).

---

### 💻 7. Suporte a Estações de Trabalho / Endpoints (`workstation/`)

* **[`Get-WorkstationDiagnostics.ps1`](./workstation/Get-WorkstationDiagnostics.ps1)**
  * **Finalidade:** Diagnóstico rápido de ponta a ponta em computadores de usuários (Help Desk N1/N2).
  * **Destaque:** Coleta Fabricante, Modelo, Service Tag/Número de Série, usuário logado, Uptime, alerta de reinicialização pendente, tipo de mídia (SSD/NVMe/HDD) e integridade SMART, saúde da bateria (desgaste em % se notebook), status de antivírus Defender, BitLocker, histórico de Telas Azuis (BSOD/minidumps) e rede ativa com sinal Wi-Fi.
  * **Exemplo de uso:**
    ```powershell
    .\workstation\Get-WorkstationDiagnostics.ps1
    .\workstation\Get-WorkstationDiagnostics.ps1 -ExportHtml
    ```

* **[`Optimize-WorkstationPerformance.ps1`](./workstation/Optimize-WorkstationPerformance.ps1)**
  * **Finalidade:** Melhora a performance de computadores lentos de usuários finais.
  * **Destaque:** Limpa caches de navegadores (Edge e Chrome) sem apagar senhas ou histórico, esvazia caches de miniaturas e de Otimização de Entrega do Windows, executa o comando TRIM para restaurar a velocidade de escrita de SSDs, limpa cache DNS e audita programas que atrasam a inicialização do Windows (Startup).
  * **Exemplo de uso:**
    ```powershell
    .\workstation\Optimize-WorkstationPerformance.ps1
    .\workstation\Optimize-WorkstationPerformance.ps1 -SetHighPerformance
    ```

* **[`Install-RemoteSoftware.ps1`](./workstation/Install-RemoteSoftware.ps1)**
  * **Finalidade:** Instala softwares silenciosamente em segundo plano, de forma local ou remota (via WinRM/PowerShell Remoting).
  * **Destaque:** Suporta instalação automática pelo catálogo do **Winget** (ex: Chrome, Firefox, 7-Zip, AnyDesk, Adobe Reader) ou por pacotes customizados **MSI / EXE** em compartilhamento de rede com parâmetros silenciosos.
  * **Exemplo de uso:**
    ```powershell
    # Instalar localmente ou remotamente via Winget
    .\workstation\Install-RemoteSoftware.ps1 -PackageId "Google.Chrome"
    .\workstation\Install-RemoteSoftware.ps1 -ComputerName "PC-USER-01", "PC-USER-02" -PackageId "7zip.7zip"

    # Instalar remotamente pacote MSI da rede
    .\workstation\Install-RemoteSoftware.ps1 -ComputerName "PC-USER-05" -InstallerPath "\\servidor\softwares\agente.msi"
    ```

* **[`Repair-WindowsUpdate.ps1`](./workstation/Repair-WindowsUpdate.ps1)**
  * **Finalidade:** Corrige computadores com travamentos, alto uso de CPU e falhas de instalação no Windows Update, com correção dedicada para o erro **`0x80004002`** (`E_NOINTERFACE`).
  * **Destaque:**
    * **Correção 0x80004002:** Re-registra todas as bibliotecas COM e Proxy-Stubs do WUA (`wups2.dll`, `wups.dll`, `wuaueng.dll`, `wuapi.dll`, etc.) que causam o erro de interface não suportada.
    * Restaura descritores de segurança (SDDL) nos serviços `wuauserv` e `bits`.
    * Garante a inicialização correta do `TrustedInstaller` (Windows Modules Installer) e do orquestrador `UsoSvc`.
    * Limpa caches corrompidos (`SoftwareDistribution` e `catroot2`) e reseta Winsock/WinHTTP.
    * Suporte a reparo profundo de imagem (`-DeepRepair`) via DISM e SFC e remoção de políticas órfãs de WSUS (`-ResetWsusPolicy`).
  * **Exemplo de uso:**
    ```powershell
    # Reparo padrão (inclui re-registro de DLLs e resolução do erro 0x80004002)
    .\workstation\Repair-WindowsUpdate.ps1

    # Reparo avançado com DISM, SFC e limpeza de WSUS
    .\workstation\Repair-WindowsUpdate.ps1 -DeepRepair -ResetWsusPolicy
    ```

---

## ⚙️ Pré-requisitos & Recomendações

1. **Permissões:** Execute o console do PowerShell como **Administrador** (`Run as Administrator`) para obter acesso completo a métricas de sistema, serviços, eventos e gerenciamento de arquivos.
2. **Política de Execução:** Caso receba aviso sobre execução de scripts bloqueada, ajuste a política na sessão:
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope Process
   ```
3. **Módulos Opcionais:**
   * **ActiveDirectory:** Necessário para o script `Audit-LockedAccounts.ps1` (disponível via RSAT).
   * **Hyper-V:** Necessário para os scripts de gerenciamento do Hyper-V.
