# Requirements Document

## Introduction

Este documento define os requisitos para a infraestrutura completa de um servidor privado de Ragnarok Online baseado no emulador rAthena. A solução abrange compilação e containerização do rAthena (Login Server, Char Server e Map Server), banco de dados MariaDB 11, orquestração via Docker Compose em Ubuntu 24.04, pipeline de CI/CD com GitHub Actions, monitoramento com Zabbix e Grafana, backup e recuperação de desastres, hardening de segurança, painel de controle web (FluxCP) e procedimentos operacionais documentados.

O objetivo é fornecer uma infraestrutura de produção reproduzível, segura, monitorada e com recuperação automatizada — seguindo as melhores práticas de Docker (2026), segurança de servidores Linux, administração de bancos de dados e proteção contra ataques comuns a servidores de jogos online.

Referências:
- [rAthena GitHub](https://github.com/rathena/rathena)
- [rAthena Wiki - Installation](https://github.com/rathena/rathena/wiki/Installation)
- [MariaDB Docker Official Docs](https://mariadb.com/docs/server/server-management/automated-mariadb-deployment-and-administration/docker-and-mariadb/installing-and-using-mariadb-via-docker)
- [Zabbix Docker Deployment](https://blog.zabbix.com/deploying-zabbix-components-with-docker-and-docker-compose/30025/)
- [Docker Best Practices 2026](https://thinksys.com/devops/docker-best-practices/)

## Glossary

- **Infraestrutura**: Conjunto de containers Docker, volumes, redes e configurações que compõem o ambiente de produção do servidor rAthena
- **Login_Server**: Serviço rAthena responsável pela autenticação de jogadores, gerenciamento de contas e comunicação inicial com o cliente (porta 6900)
- **Char_Server**: Serviço rAthena responsável pelo gerenciamento de personagens, guilds, armazenamento de dados e comunicação com Login_Server (porta 6121)
- **Map_Server**: Serviço rAthena responsável pela lógica de jogo, mapas, NPCs, monstros, combate e interações em tempo real (porta 5121)
- **MariaDB**: Sistema de gerenciamento de banco de dados relacional versão 11.4 LTS, responsável pelo armazenamento persistente de todos os dados do servidor (contas, personagens, itens, guilds)
- **Docker_Compose**: Ferramenta de orquestração de containers que define e gerencia os serviços multi-container do ambiente via arquivo YAML declarativo
- **Pipeline_CICD**: Conjunto de workflows do GitHub Actions que automatizam validação, build, teste e deploy da infraestrutura
- **Zabbix**: Sistema de monitoramento enterprise que coleta métricas de infraestrutura e serviços, gerando alertas operacionais com severidade configurável
- **Grafana**: Plataforma de visualização de métricas e dashboards para observabilidade do ambiente, conectada ao Zabbix como datasource
- **FluxCP**: Painel de controle web (PHP) para administração do servidor rAthena, permitindo registro de jogadores, gerenciamento de contas e estatísticas
- **Volume_Persistente**: Storage Docker nomeado e persistente que mantém dados entre reinicializações e atualizações de containers
- **Backup_Service**: Container dedicado que executa cópias de segurança automatizadas dos dados críticos em horários programados
- **Firewall**: Conjunto de regras UFW (Uncomplicated Firewall) que controlam o tráfego de entrada e saída do servidor host com política default-deny
- **Healthcheck**: Verificação periódica automatizada via Docker que confirma se um serviço está operacional e respondendo corretamente
- **Runbook**: Documento operacional com procedimentos passo a passo para resolução de incidentes e operações de rotina
- **Rede_Interna**: Rede Docker bridge isolada (internal: true) usada exclusivamente para comunicação entre os serviços sem acesso externo
- **Rede_Externa**: Rede Docker bridge com portas expostas ao host para acesso de jogadores e administradores
- **Fail2ban**: Daemon de proteção contra brute-force que monitora logs e bloqueia IPs após múltiplas tentativas falhas de autenticação
- **Binary_Log**: Log binário do MariaDB que registra todas as alterações de dados, permitindo recuperação point-in-time (PITR)
- **PACKETVER**: Versão do protocolo de rede do Ragnarok Online (formato YYYYMMDD) que deve ser definida em tempo de compilação para compatibilidade com o cliente do jogo
- **Inter_Server_Password**: Senha compartilhada configurada em inter_athena.conf para autenticação na comunicação entre Login_Server, Char_Server e Map_Server

## Requirements

### Requirement 1: Infraestrutura Docker Compose

**User Story:** Como administrador do servidor, eu quero uma infraestrutura Docker Compose completa e bem estruturada, para que eu possa orquestrar todos os serviços do rAthena de forma reproduzível, isolada e seguindo as melhores práticas de containerização 2026.

#### Acceptance Criteria

1. THE Infraestrutura SHALL definir um arquivo docker-compose.yml na raiz do projeto contendo todos os serviços: Login_Server, Char_Server, Map_Server, MariaDB, Zabbix Server, Zabbix Web, Zabbix Agent, Grafana, Backup_Service e FluxCP
2. THE Infraestrutura SHALL definir uma Rede_Interna (driver bridge, internal: true) dedicada para comunicação entre os serviços rAthena e o MariaDB, sem exposição ao host
3. THE Infraestrutura SHALL definir uma Rede_Externa separada para expor apenas as portas necessárias para acesso externo: 6900 (Login_Server), 6121 (Char_Server), 5121 (Map_Server), 3000 (Grafana), 443 (Zabbix Web), 80 (FluxCP)
4. WHEN o comando "docker compose up -d" é executado, THE Infraestrutura SHALL iniciar todos os serviços na ordem correta respeitando dependências via depends_on com condition service_healthy
5. THE Infraestrutura SHALL definir limites de recursos (CPU e memória) para cada container via configuração deploy.resources.limits no docker-compose.yml
6. THE Infraestrutura SHALL utilizar imagens Docker com versões fixas (pinadas) em todos os serviços, sem utilizar a tag "latest"
7. THE Infraestrutura SHALL centralizar configurações sensíveis e específicas do ambiente em um arquivo .env referenciado pelo docker-compose.yml
8. THE Infraestrutura SHALL definir a política de reinicialização "unless-stopped" para todos os serviços de produção
9. THE Infraestrutura SHALL utilizar volumes nomeados (named volumes) para todos os dados persistentes, evitando bind mounts para dados críticos

### Requirement 2: Compilação e Containerização do rAthena

**User Story:** Como administrador do servidor, eu quero que o rAthena seja compilado automaticamente dentro de um container Docker multi-stage, para que eu tenha builds reproduzíveis, imagens mínimas, seguras e sem dependências do ambiente host.

#### Acceptance Criteria

1. THE Infraestrutura SHALL fornecer um Dockerfile multi-stage que compila o rAthena a partir do código-fonte oficial (https://github.com/rathena/rathena) na fase de build e copia apenas os binários e arquivos necessários para a imagem final
2. WHEN o build do Docker é executado, THE Infraestrutura SHALL compilar o rAthena com suporte a MariaDB habilitado (--enable-manager=yes) e com PACKETVER configurável via build argument; o PACKETVER SHALL ser definido como ARG no Dockerfile com valor padrão e pode ser alterado sem necessidade de re-execução prévia do build
3. THE Infraestrutura SHALL aceitar o PACKETVER como argumento de build (ARG) com valor padrão documentado, permitindo compatibilidade com diferentes versões do cliente RO
4. THE Infraestrutura SHALL gerar imagens Docker separadas para Login_Server, Char_Server e Map_Server utilizando targets distintos no mesmo Dockerfile multi-stage
5. THE Infraestrutura SHALL executar todos os processos rAthena dentro dos containers com um usuário não-root dedicado (UID 1000, GID 1000)
6. THE Infraestrutura SHALL montar os arquivos de configuração (conf/) como volumes externos para permitir ajustes sem rebuild da imagem
7. THE Infraestrutura SHALL montar os scripts NPC customizados (npc/custom/) como volumes externos para permitir personalização do servidor
8. WHEN o Login_Server inicia com sucesso, THE Login_Server SHALL conectar-se ao MariaDB e aceitar conexões de jogadores na porta 6900; IF a conexão com MariaDB falha durante a inicialização, THEN a inicialização SHALL ser considerada falha e o healthcheck SHALL reportar unhealthy
9. WHEN o Char_Server inicia com sucesso, THE Char_Server SHALL autenticar-se no Login_Server usando a Inter_Server_Password e aceitar conexões na porta 6121
10. WHEN o Map_Server inicia com sucesso, THE Map_Server SHALL autenticar-se no Char_Server usando a Inter_Server_Password e aceitar conexões na porta 5121
11. THE Infraestrutura SHALL fornecer arquivos de configuração padrão (inter_athena.conf, char_athena.conf, map_athena.conf, login_athena.conf) com valores parametrizados via variáveis de ambiente usando script de entrypoint
12. THE Infraestrutura SHALL utilizar imagem base Debian slim na fase final do multi-stage para minimizar o tamanho da imagem de produção enquanto mantém compatibilidade com as bibliotecas do rAthena
13. THE Infraestrutura SHALL instalar apenas as dependências de runtime na imagem final (libmariadb3, libz, libpcre) sem incluir compiladores ou headers

### Requirement 3: Banco de Dados MariaDB

**User Story:** Como administrador do servidor, eu quero um banco de dados MariaDB 11.4 LTS configurado com persistência garantida, tuning adequado para game server e princípio de menor privilégio, para que os dados dos jogadores sejam preservados com performance e segurança.

#### Acceptance Criteria

1. THE MariaDB SHALL utilizar a imagem oficial mariadb:11.4 (versão LTS pinada) como base do container
2. THE MariaDB SHALL armazenar todos os dados em um Volume_Persistente nomeado mapeado para /var/lib/mysql
3. WHEN o container MariaDB inicia pela primeira vez, THE MariaDB SHALL executar os scripts de inicialização SQL do rAthena (main.sql, logs.sql) automaticamente via o diretório /docker-entrypoint-initdb.d/
4. THE MariaDB SHALL aceitar conexões apenas da Rede_Interna, sem expor a porta 3306 ao host (bind-address=0.0.0.0 apenas na rede interna Docker)
5. THE MariaDB SHALL criar um usuário dedicado para o rAthena com privilégios restritos (SELECT, INSERT, UPDATE, DELETE) apenas no banco de dados do jogo
6. THE MariaDB SHALL criar um usuário separado para backup com privilégio SELECT e LOCK TABLES apenas
7. THE MariaDB SHALL configurar charset utf8mb4 e collation utf8mb4_general_ci como padrão para compatibilidade com dados do rAthena
8. WHEN o MariaDB recebe um Healthcheck, THE MariaDB SHALL responder com status saudável via comando "healthcheck.sh --connect --innodb_initialized" (script oficial da imagem MariaDB)
9. THE MariaDB SHALL configurar innodb_buffer_pool_size para 50% da memória alocada ao container
10. THE MariaDB SHALL habilitar binary logging (log-bin=mysql-bin) para permitir recuperação point-in-time
11. THE MariaDB SHALL configurar slow_query_log habilitado com long_query_time de 2 segundos para identificar queries com performance degradada
12. THE MariaDB SHALL remover o banco de dados "test" e usuários anônimos na inicialização via script de setup
13. THE MariaDB SHALL configurar max_connections adequado ao número esperado de jogadores simultâneos (padrão: 151, configurável via .env)
14. THE MariaDB SHALL garantir um innodb_buffer_pool_size mínimo de 128MB independentemente do cálculo de 50% da memória do container, prevenindo falha de inicialização em ambientes com pouca memória

### Requirement 4: Pipeline de CI/CD com GitHub Actions

**User Story:** Como administrador do servidor, eu quero um pipeline de CI/CD automatizado com GitHub Actions, para que mudanças na infraestrutura sejam validadas antes do deploy e o processo de deploy seja controlado, auditável e com capacidade de rollback.

#### Acceptance Criteria

1. WHEN um pull request é criado ou atualizado, THE Pipeline_CICD SHALL executar validação de sintaxe dos Dockerfiles via hadolint e do docker-compose.yml via "docker compose config --quiet"
2. WHEN um pull request é criado ou atualizado, THE Pipeline_CICD SHALL executar build de teste das imagens Docker sem publicá-las para validar que a compilação do rAthena é bem-sucedida
3. WHEN um merge é feito na branch principal, THE Pipeline_CICD SHALL construir as imagens Docker com tag baseada no SHA curto do commit e armazená-las no GitHub Container Registry (ghcr.io)
4. WHEN o workflow de deploy é acionado manualmente (workflow_dispatch), THE Pipeline_CICD SHALL exigir tanto a conexão SSH bem-sucedida quanto o acionamento manual antes de executar qualquer atualização no servidor (pull de imagens, recreate dos containers afetados)
5. THE Pipeline_CICD SHALL validar que o arquivo .env.example contém todas as variáveis referenciadas no docker-compose.yml e nos arquivos de configuração
6. IF o build de uma imagem Docker falha, THEN THE Pipeline_CICD SHALL interromper o pipeline, garantir que o commit seja marcado como falho no GitHub e registrar os logs de erro completos como artefato do workflow, independentemente do tipo de falha
7. THE Pipeline_CICD SHALL armazenar secrets (SSH_PRIVATE_KEY, SERVER_HOST, SERVER_USER, GHCR_TOKEN) de forma segura nos GitHub Secrets, sem exposição em logs
8. THE Pipeline_CICD SHALL fornecer um workflow de rollback que reverte para a versão anterior das imagens Docker via tag do commit anterior
9. WHEN o deploy é executado, THE Pipeline_CICD SHALL criar um backup do banco de dados antes de aplicar a atualização
10. THE Pipeline_CICD SHALL executar validação de shell scripts via shellcheck para scripts de provisionamento e backup

### Requirement 5: Monitoramento com Zabbix

**User Story:** Como administrador do servidor, eu quero monitoramento completo via Zabbix com alertas configurados e notificações, para que eu seja notificado sobre problemas de infraestrutura e serviços antes que impactem os jogadores.

#### Acceptance Criteria

1. THE Infraestrutura SHALL incluir containers Zabbix Server (zabbix-server-mysql), Zabbix Web Frontend (zabbix-web-nginx-mysql) e Zabbix Agent (zabbix-agent2) no docker-compose.yml com versões pinadas
2. THE Zabbix SHALL monitorar métricas de CPU, memória, disco e rede do host via Zabbix Agent2
3. THE Zabbix SHALL monitorar a disponibilidade dos processos Login_Server, Char_Server e Map_Server via verificação de porta TCP (net.tcp.port)
4. THE Zabbix SHALL monitorar métricas do MariaDB (conexões ativas, queries por segundo, slow queries, uso de buffer pool) via template oficial "MySQL by Zabbix agent"
5. WHEN a utilização de CPU de qualquer container excede 80% por mais de 5 minutos E a leitura de CPU é válida (maior que 0%), THE Zabbix SHALL gerar um alerta de severidade "High"; leituras de 0% ou inválidas SHALL ser descartadas sem gerar alerta
6. WHEN a utilização de memória de qualquer container excede 85% por mais de 3 minutos, THE Zabbix SHALL gerar um alerta de severidade "High"
7. WHEN o espaço em disco disponível é inferior a 10% da capacidade total, THE Zabbix SHALL gerar um alerta de severidade "Disaster"
8. WHEN qualquer serviço rAthena (Login_Server, Char_Server ou Map_Server) não responde na porta TCP esperada por mais de 30 segundos, THE Zabbix SHALL gerar um alerta de severidade "Disaster"
9. THE Zabbix SHALL reter dados de métricas (history) por no mínimo 90 dias e dados de tendência (trends) por 365 dias
10. WHEN um alerta de severidade "High" ou "Disaster" é gerado, THE Zabbix SHALL enviar notificação via webhook configurável (Discord, Telegram ou Slack)
11. THE Zabbix SHALL utilizar banco de dados MariaDB separado do banco do rAthena para armazenar dados de monitoramento

### Requirement 6: Dashboards Grafana

**User Story:** Como administrador do servidor, eu quero dashboards Grafana pré-configurados e provisionados automaticamente, para que eu possa visualizar o estado do servidor e tendências de performance em tempo real sem configuração manual.

#### Acceptance Criteria

1. THE Infraestrutura SHALL incluir um container Grafana (grafana/grafana-oss) com versão pinada conectado ao Zabbix como datasource principal via plugin Zabbix
2. WHEN o container Grafana inicia, THE Grafana SHALL provisionar automaticamente datasources e dashboards pré-configurados via diretório /etc/grafana/provisioning/ (YAML para datasources, JSON para dashboards); IF o provisioning de datasources falha, THEN dashboards SHALL NOT ser provisionados e o container SHALL registrar o erro no log
3. THE Grafana SHALL exibir um dashboard "Server Overview" com status operacional de todos os serviços (Login_Server, Char_Server, Map_Server, MariaDB) usando indicadores de status verde/amarelo/vermelho
4. THE Grafana SHALL exibir um dashboard "Database Performance" com métricas de queries por segundo, conexões ativas, uso de buffer pool, slow queries e tamanho do banco
5. THE Grafana SHALL exibir um dashboard "Host Resources" com métricas de CPU, memória, disco e rede plotadas ao longo do tempo com granularidade de 1 minuto
6. THE Grafana SHALL ser acessível via porta 3000 com autenticação habilitada e credenciais de admin definidas no arquivo .env (GF_SECURITY_ADMIN_USER, GF_SECURITY_ADMIN_PASSWORD)
7. THE Grafana SHALL armazenar configurações e dashboards customizados em um Volume_Persistente para preservar alterações entre reinicializações

### Requirement 7: Backup e Recuperação de Desastres

**User Story:** Como administrador do servidor, eu quero backups automáticos diários com retenção de 30 dias, restauração testável e capacidade de recuperação point-in-time, para que eu possa recuperar dados em caso de falha catastrófica com perda mínima de dados de jogadores.

#### Acceptance Criteria

1. THE Backup_Service SHALL executar um backup completo do banco de dados MariaDB diariamente às 04:00 UTC via mariadb-dump com opções --single-transaction --routines --triggers --events
2. THE Backup_Service SHALL comprimir os arquivos de backup usando gzip e nomear cada arquivo com padrão "rathena_db_YYYY-MM-DD_HHmmss.sql.gz"
3. THE Backup_Service SHALL reter backups por 30 dias e remover automaticamente backups mais antigos via rotação diária
4. THE Backup_Service SHALL armazenar backups em um Volume_Persistente separado do volume de dados do MariaDB
5. THE Backup_Service SHALL registrar em log o resultado de cada operação de backup (sucesso ou falha) incluindo timestamp, tamanho do arquivo gerado e duração da operação
6. IF um backup falha, THEN THE Backup_Service SHALL enviar uma notificação via webhook configurável (Discord, Telegram ou Slack) com detalhes do erro incluindo código de saída e últimas linhas do log
7. THE Infraestrutura SHALL fornecer um script de restauração (restore.sh) documentado que aceita um arquivo de backup como argumento, para os serviços rAthena, restaura o banco e reinicia os serviços
8. WHEN o script de restauração é executado com um arquivo de backup válido, THE Infraestrutura SHALL restaurar o banco de dados ao estado do backup selecionado em menos de 15 minutos para bancos de até 5GB; WHEN o banco excede 5GB, THE Infraestrutura SHALL permitir tempos de restauração proporcionais (estimativa de 3 minutos por GB adicional) e registrar o progresso em log
9. THE Backup_Service SHALL incluir backup dos arquivos de configuração (conf/) e scripts NPC customizados (npc/custom/) em arquivo tar.gz separado com padrão "rathena_config_YYYY-MM-DD.tar.gz"
10. THE MariaDB SHALL manter Binary_Logs (expire_logs_days=7) por 7 dias para permitir recuperação point-in-time entre backups completos
11. THE Infraestrutura SHALL documentar os objetivos de RTO (Recovery Time Objective) de 30 minutos e RPO (Recovery Point Objective) de 24 horas para o cenário de backup completo, e RPO de minutos para cenário com binary logs

### Requirement 8: Segurança e Hardening

**User Story:** Como administrador do servidor, eu quero que a infraestrutura siga boas práticas de segurança e hardening, para que o servidor esteja protegido contra ataques comuns a game servers (DDoS, brute-force, exploits), acessos não autorizados e vulnerabilidades conhecidas do rAthena.

#### Acceptance Criteria

1. THE Infraestrutura SHALL configurar acesso SSH apenas via chaves públicas, desabilitando PasswordAuthentication e PermitRootLogin no sshd_config
2. THE Firewall SHALL implementar política default DROP (INPUT e FORWARD) e automaticamente permitir tráfego de entrada nas portas de serviço: SSH (configurável, padrão 22), 6900, 6121, 5121 (rAthena), 3000 (Grafana), 443 (Zabbix Web), 80 (FluxCP) — sem requerer configuração adicional além do script de provisionamento
3. THE Infraestrutura SHALL executar todos os processos rAthena dentro dos containers com usuário não-root (UID 1000, GID 1000, definido no Dockerfile)
4. THE Infraestrutura SHALL configurar containers rAthena com filesystem read-only (read_only: true) e tmpfs para /tmp e /run
5. THE MariaDB SHALL aceitar conexões apenas de hosts na Rede_Interna via configuração de rede Docker (sem port binding no host)
6. WHEN mais de 5 tentativas de autenticação SSH falham em 60 segundos de um mesmo IP, THE Fail2ban SHALL bloquear o IP de origem por 600 segundos
7. THE Infraestrutura SHALL configurar unattended-upgrades no host Ubuntu 24.04 para aplicação automática de patches de segurança do sistema operacional
8. THE Infraestrutura SHALL fornecer um script de hardening (hardening.sh) que configura: sysctl de rede (net.ipv4.tcp_syncookies=1, net.ipv4.conf.all.rp_filter=1), desabilita IPv6 se não utilizado, configura limites de arquivo e remove pacotes desnecessários
9. THE Infraestrutura SHALL gerar senhas aleatórias fortes (mínimo 32 caracteres alfanuméricos + especiais) no primeiro deploy quando credenciais não forem fornecidas no .env; IF credenciais fracas forem fornecidas (menos de 16 caracteres ou sem caracteres especiais), THEN THE Infraestrutura SHALL exibir um aviso no log e recomendar a troca, mas permitir a inicialização
10. THE Infraestrutura SHALL proteger o socket do Docker (chmod 660, ownership root:docker) limitando acesso ao grupo docker e ao usuário administrador
11. THE Infraestrutura SHALL implementar rate limiting nas portas dos serviços rAthena (6900, 6121, 5121) via iptables/nftables para limitar novas conexões por IP (máximo 10 conexões/segundo por IP)
12. THE Infraestrutura SHALL configurar Inter_Server_Password forte e única em inter_athena.conf para autenticação entre Login_Server, Char_Server e Map_Server
13. THE Infraestrutura SHALL manter o rAthena atualizado com patches de segurança, documentando o processo de atualização para mitigar CVEs conhecidas (ex: CVE-2025-58447, CVE-2025-58448, CVE-2025-58750)

### Requirement 9: Healthchecks e Auto-Recuperação

**User Story:** Como administrador do servidor, eu quero que todos os serviços tenham healthchecks configurados e se recuperem automaticamente de falhas transitórias, para que o servidor mantenha alta disponibilidade sem intervenção manual constante.

#### Acceptance Criteria

1. THE Infraestrutura SHALL configurar healthchecks Docker para todos os serviços com intervalo de 30 segundos, timeout de 10 segundos, start_period de 120 segundos (tempo para compilação/inicialização) e retries de 3
2. THE Login_Server SHALL responder ao healthcheck via verificação de conexão TCP na porta 6900 (usando nc ou ss)
3. THE Char_Server SHALL responder ao healthcheck via verificação de conexão TCP na porta 6121
4. THE Map_Server SHALL responder ao healthcheck via verificação de conexão TCP na porta 5121
5. THE MariaDB SHALL responder ao healthcheck via script oficial "healthcheck.sh --connect --innodb_initialized"
6. WHEN o healthcheck de qualquer serviço falha 3 vezes consecutivas, THE Docker_Compose SHALL reiniciar o container automaticamente via política restart: unless-stopped
7. THE Infraestrutura SHALL configurar depends_on com condition service_healthy para garantir a cadeia de dependências: MariaDB → Login_Server → Char_Server → Map_Server; WHEN todas as dependências estão healthy, THE serviço dependente SHALL iniciar automaticamente sem gate adicional

### Requirement 10: Runbook Operacional

**User Story:** Como administrador do servidor, eu quero um runbook completo com procedimentos de operação e tabela de decisão, para que eu consiga diagnosticar e resolver incidentes rapidamente seguindo passos documentados, minimizando tempo de indisponibilidade.

#### Acceptance Criteria

1. THE Runbook SHALL documentar procedimentos de diagnóstico e resolução para falha do Login_Server incluindo: container não inicia, recusa conexões na porta 6900, erro de autenticação de jogadores, falha de conexão com MariaDB
2. THE Runbook SHALL documentar procedimentos de diagnóstico e resolução para falha do Char_Server incluindo: não conecta ao Login_Server, erro ao carregar dados de personagem, timeout de comunicação, Inter_Server_Password incorreta
3. THE Runbook SHALL documentar procedimentos de diagnóstico e resolução para falha do Map_Server incluindo: crash recorrente, lag excessivo (high tick time), desconexão em massa de jogadores, consumo excessivo de memória
4. THE Runbook SHALL documentar procedimentos de diagnóstico e resolução para falha do MariaDB incluindo: container não inicia, corrupção de tabela InnoDB, performance degradada (slow queries), locks excessivos, disco cheio
5. THE Runbook SHALL documentar o procedimento completo de restore de backup incluindo: parada dos serviços rAthena, restauração do dump SQL, verificação de integridade dos dados e reinicialização controlada
6. THE Runbook SHALL documentar o procedimento de atualização do rAthena incluindo: verificação de CVEs, backup pré-atualização, pull do código novo, rebuild de imagens, deploy com validação e rollback em caso de falha
7. THE Runbook SHALL documentar comandos úteis de diagnóstico organizados por categoria: logs de containers, métricas de sistema, conexões ativas no MariaDB, queries lentas, estado dos healthchecks
8. THE Runbook SHALL incluir uma tabela de decisão com colunas: sintoma observado, severidade, possíveis causas, comandos de diagnóstico e ação recomendada

### Requirement 11: Deploy e Provisionamento Inicial

**User Story:** Como administrador do servidor, eu quero um processo de provisionamento automatizado e documentado, para que eu possa configurar o ambiente completo do zero em uma nova máquina Ubuntu 24.04 de forma rápida, confiável e idempotente.

#### Acceptance Criteria

1. THE Infraestrutura SHALL fornecer um script de provisionamento (setup.sh) que instala Docker Engine e Docker Compose Plugin no Ubuntu 24.04 via repositório oficial do Docker
2. WHEN o script de provisionamento é executado em um Ubuntu 24.04 limpo, THE Infraestrutura SHALL instalar e configurar: Docker, UFW (firewall), fail2ban, unattended-upgrades, logrotate e diretórios de dados em uma única execução
3. THE Infraestrutura SHALL fornecer um arquivo .env.example documentado com todas as variáveis necessárias, valores de exemplo seguros e comentários explicativos para cada variável agrupados por serviço
4. WHEN o comando "docker compose up -d" é executado pela primeira vez, THE Infraestrutura SHALL inicializar o banco de dados com o schema do rAthena, compilar os binários e iniciar todos os serviços sem intervenção manual adicional
5. THE Infraestrutura SHALL documentar os pré-requisitos mínimos do servidor: 4GB RAM, 2 vCPUs, 40GB disco SSD, Ubuntu 24.04 LTS, acesso root ou sudo
6. IF o script de provisionamento detecta que o Docker já está instalado e funcional, THEN THE Infraestrutura SHALL pular a instalação do Docker e prosseguir com a configuração restante (firewall, fail2ban, diretórios)
7. THE Infraestrutura SHALL fornecer documentação clara de primeiro deploy com sequência de comandos numerada do clone do repositório até o servidor operacional e primeiro login de jogador, garantindo que seguir os passos documentados resulte em um servidor funcional sem intervenção adicional

### Requirement 12: Logging e Rotação de Logs

**User Story:** Como administrador do servidor, eu quero que todos os logs dos serviços sejam centralizados, rotacionados automaticamente e facilmente consultáveis, para que eu possa investigar problemas, auditar eventos e manter o uso de disco sob controle.

#### Acceptance Criteria

1. THE Infraestrutura SHALL configurar o Docker logging driver como json-file com rotação automática (max-size: 50m, max-file: 5) para todos os containers via docker-compose.yml
2. THE Infraestrutura SHALL armazenar logs aplicacionais do rAthena (login-server.log, char-server.log, map-server.log) em volumes persistentes mapeados para diretório no host (/opt/rathena/logs/)
3. THE Infraestrutura SHALL configurar logrotate no host para rotacionar logs aplicacionais do rAthena com retenção de 7 dias, compressão gzip e rotação diária
4. WHEN um erro crítico ocorre em qualquer serviço rAthena, THE Infraestrutura SHALL registrar o evento no log do container com timestamp e mensagem descritiva acessível via "docker compose logs"
5. THE Runbook SHALL documentar comandos para consultar logs filtrados por serviço, intervalo de data e palavras-chave usando docker compose logs e grep/jq no host

### Requirement 13: Painel de Controle Web (FluxCP)

**User Story:** Como administrador do servidor, eu quero um painel de controle web (FluxCP) containerizado, para que jogadores possam se registrar, gerenciar contas e visualizar informações do servidor via navegador, sem acesso direto ao banco de dados.

#### Acceptance Criteria

1. THE Infraestrutura SHALL incluir um container FluxCP (PHP + Nginx/Apache) no docker-compose.yml com acesso à Rede_Interna para conexão ao MariaDB
2. THE FluxCP SHALL ser acessível via porta 80 (HTTP) na Rede_Externa, com possibilidade de configuração de HTTPS via proxy reverso
3. THE FluxCP SHALL utilizar credenciais de banco de dados com privilégios restritos (SELECT, INSERT, UPDATE, DELETE) no banco do rAthena
4. THE FluxCP SHALL ser configurável via variáveis de ambiente para: nome do servidor, endereço do banco de dados, tema e funcionalidades habilitadas
5. WHEN o container FluxCP inicia, THE FluxCP SHALL conectar-se ao MariaDB e exibir a página inicial sem erros de conexão; IF o MariaDB está indisponível, THEN THE FluxCP SHALL exibir uma página de erro amigável informando que o serviço está temporariamente indisponível, sem expor detalhes internos de conexão, e o container SHALL continuar rodando com retry automático
6. THE FluxCP SHALL armazenar uploads e configurações customizadas em um Volume_Persistente

### Requirement 14: Proteção contra DDoS e Abuso

**User Story:** Como administrador do servidor, eu quero proteção contra ataques DDoS e abuso nas portas do jogo, para que jogadores legítimos mantenham acesso mesmo durante tentativas de ataque, que são comuns em servidores de jogos online.

#### Acceptance Criteria

1. THE Firewall SHALL implementar rate limiting de novas conexões TCP nas portas do rAthena (6900, 6121, 5121) limitando a 10 novas conexões por segundo por IP de origem
2. THE Firewall SHALL implementar limite de conexões simultâneas por IP nas portas do rAthena (máximo 20 conexões simultâneas por IP)
3. WHEN um IP excede o rate limit configurado, THE Firewall SHALL descartar (DROP) pacotes excedentes sem enviar resposta (para não amplificar)
4. THE Infraestrutura SHALL configurar regras sysctl otimizadas para mitigação de SYN flood: tcp_syncookies=1, tcp_max_syn_backlog=2048, netfilter conntrack com timeout reduzido
5. THE Infraestrutura SHALL documentar recomendações de proteção DDoS em camada 4 (L4) específicas para game servers, incluindo opções de provedores com proteção anti-DDoS (OVH Game, Hetzner, Path.net)
6. THE Login_Server SHALL limitar tentativas de login a no máximo 5 tentativas por IP via configuração do rAthena (allowed_regs e time_allowed), aplicando o limite incondicionalmente para prevenir brute-force de contas

