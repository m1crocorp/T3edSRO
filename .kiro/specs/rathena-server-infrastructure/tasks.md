# Implementation Plan: Infraestrutura rAthena Server

## Overview

Este plano implementa a infraestrutura completa de produção para o servidor rAthena, seguindo uma abordagem incremental: estrutura do projeto → build Docker → banco de dados → orquestração → segurança → monitoramento → backup → CI/CD → documentação operacional. Cada etapa constrói sobre a anterior e termina com validação funcional.

## Tasks

- [x] 1. Estrutura do projeto e configurações base
  - [x] 1.1 Criar estrutura de diretórios e arquivo .env.example
    - Criar a árvore de diretórios conforme design: `docker/`, `docker/fluxcp/`, `conf/templates/`, `sql/`, `npc/custom/`, `db/conf.d/`, `monitoring/grafana/provisioning/datasources/`, `monitoring/grafana/provisioning/dashboards/`, `monitoring/grafana/dashboards/`, `monitoring/zabbix/templates/`, `scripts/backup/`, `.github/workflows/`, `docs/`
    - Criar `.env.example` documentado com todas as variáveis agrupadas por serviço (MariaDB, rAthena, Zabbix, Grafana, FluxCP, Backup) com valores de exemplo seguros e comentários explicativos
    - _Requirements: 1.7, 11.3_

  - [x] 1.2 Criar templates de configuração do rAthena
    - Criar `conf/templates/inter_athena.conf.tmpl` com placeholders `${DB_HOST}`, `${DB_USER}`, `${DB_PASS}`, `${INTER_SERVER_PASSWORD}`
    - Criar `conf/templates/login_athena.conf.tmpl` com placeholders para porta e configurações de login
    - Criar `conf/templates/char_athena.conf.tmpl` com placeholders para porta e nome do servidor
    - Criar `conf/templates/map_athena.conf.tmpl` com placeholders para porta e configurações de mapa
    - _Requirements: 2.11, 2.6, 8.12_

  - [x] 1.3 Criar configuração customizada do MariaDB (custom.cnf)
    - Criar `db/conf.d/custom.cnf` com tuning: innodb_buffer_pool_size=1024M, innodb_log_file_size=256M, innodb_flush_log_at_trx_commit=2, max_connections=151, charset utf8mb4, collation utf8mb4_general_ci, binary logging (log-bin=mysql-bin, expire_logs_days=7), slow query log (long_query_time=2), skip-name-resolve
    - _Requirements: 3.7, 3.9, 3.10, 3.11, 3.13, 3.14, 7.10_

  - [x] 1.4 Criar scripts SQL de inicialização do banco
    - Criar `sql/00-setup-users.sql` que: remove banco test e usuários anônimos, cria usuário `rathena` com SELECT/INSERT/UPDATE/DELETE nos bancos ragnarok e ragnarok_log, cria usuário `rathena_backup` com SELECT/LOCK TABLES/SHOW VIEW/EVENT/TRIGGER, cria usuário `fluxcp` com SELECT/INSERT/UPDATE/DELETE no ragnarok, cria banco `zabbix` e usuário `zabbix` com ALL PRIVILEGES no banco zabbix
    - Criar `sql/00-init.sh` para orquestrar execução de scripts SQL na inicialização
    - _Requirements: 3.3, 3.5, 3.6, 3.12, 5.11_

- [x] 2. Dockerfile multi-stage do rAthena
  - [x] 2.1 Criar Dockerfile multi-stage com targets login, char e map
    - Implementar Stage 1 (builder): base debian:bookworm-slim, ARG PACKETVER=20211103, ARG RATHENA_BRANCH=master, instalar build deps (gcc, g++, make, git, libmariadb-dev, libmariadb-dev-compat, zlib1g-dev, libpcre3-dev), git clone --depth 1, `./configure --enable-packetver=${PACKETVER}`, `make clean && make server`
    - Implementar Stage 2a (login-server): base debian:bookworm-slim, instalar runtime deps (libmariadb3, zlib1g, libpcre3, netcat-openbsd), criar usuário rathena (UID 1000, GID 1000), copiar login-server binary + conf/ + db/, HEALTHCHECK TCP 6900 (interval=30s, timeout=10s, start-period=120s, retries=3), USER rathena, EXPOSE 6900
    - Implementar Stage 2b (char-server): mesma estrutura, copiar char-server binary, EXPOSE 6121, HEALTHCHECK TCP 6121
    - Implementar Stage 2c (map-server): mesma estrutura, copiar map-server binary + npc/, EXPOSE 5121, HEALTHCHECK TCP 5121
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.12, 2.13, 9.1_

  - [x] 2.2 Criar entrypoint scripts para cada servidor
    - Criar `docker/entrypoint-login.sh`: usa envsubst para gerar configs a partir de templates em /rathena/conf/generated/ (tmpfs), exec ./login-server
    - Criar `docker/entrypoint-char.sh`: usa envsubst para gerar configs, exec ./char-server
    - Criar `docker/entrypoint-map.sh`: usa envsubst para gerar configs, exec ./map-server
    - Todos os scripts devem escrever configs gerados em /rathena/conf/generated/ (tmpfs montado via docker-compose)
    - _Requirements: 2.11, 2.8, 2.9, 2.10_

  - [x] 2.3 Criar Dockerfile do FluxCP
    - Criar `docker/fluxcp/Dockerfile` baseado em php:8.2-apache com extensões mysql, gd, mbstring
    - Clonar FluxCP, configurar Apache, definir HEALTHCHECK via curl localhost:80
    - Criar `docker/fluxcp/docker-entrypoint.sh` para configuração dinâmica via variáveis de ambiente
    - Implementar página de erro amigável quando MariaDB está indisponível (sem expor detalhes internos)
    - _Requirements: 13.1, 13.2, 13.3, 13.4, 13.5, 13.6_

- [x] 3. Checkpoint - Validar Dockerfiles
  - Executar `hadolint Dockerfile` e `hadolint docker/fluxcp/Dockerfile` para validar best practices. Ensure all tests pass, ask the user if questions arise.

- [x] 4. Docker Compose e orquestração
  - [x] 4.1 Criar docker-compose.yml com todos os serviços
    - Definir redes: `rathena-internal` (driver: bridge, internal: true) e `rathena-external` (driver: bridge)
    - Definir volumes nomeados: rathena-db-data, rathena-backups, grafana-data, zabbix-server-data, fluxcp-data
    - Definir serviço MariaDB: imagem mariadb:11.4 pinada, volume rathena-db-data:/var/lib/mysql, mount sql/ em /docker-entrypoint-initdb.d:ro, mount db/conf.d em /etc/mysql/conf.d:ro, healthcheck oficial (healthcheck.sh --connect --innodb_initialized), rede interna apenas, sem port binding no host, deploy.resources.limits cpu 1.0 mem 2048M
    - Definir serviço login-server: build com target login-server, porta 6900:6900, depends_on mariadb (service_healthy), redes interna+externa, volumes conf/templates:ro + /opt/rathena/logs/login:/rathena/log, read_only: true, tmpfs /tmp /run /rathena/conf/generated, security_opt no-new-privileges, cap_drop ALL, deploy.resources.limits cpu 0.5 mem 512M
    - Definir serviço char-server: target char-server, porta 6121, depends_on login-server (service_healthy), mesma estrutura de segurança, cpu 0.5 mem 512M
    - Definir serviço map-server: target map-server, porta 5121, depends_on char-server (service_healthy), mount npc/custom:ro, cpu 2.0 mem 2048M
    - Definir serviço zabbix-server: imagem zabbix/zabbix-server-mysql:7.0-ubuntu-latest pinada, depends_on mariadb (service_healthy), rede interna, volume zabbix-server-data, cpu 0.5 mem 1024M
    - Definir serviço zabbix-web: imagem zabbix/zabbix-web-nginx-mysql:7.0-ubuntu-latest pinada, porta 443, depends_on zabbix-server (service_healthy), redes interna+externa, volumes para certificados TLS, cpu 0.25 mem 512M
    - Definir serviço zabbix-agent2: imagem zabbix/zabbix-agent2:7.0-ubuntu-latest pinada, mount /var/run/docker.sock:ro, depends_on zabbix-server (service_started), rede interna, cpu 0.25 mem 256M
    - Definir serviço grafana: imagem grafana/grafana-oss:11.6.0 pinada, porta 3000, depends_on zabbix-server (service_healthy), volumes provisioning:ro + dashboards:ro + grafana-data, redes interna+externa, cpu 0.5 mem 512M
    - Definir serviço backup: imagem mariadb:11.4, mount scripts/backup:ro + rathena-backups + conf:ro + npc/custom:ro, rede interna, entrypoint cron, cpu 0.25 mem 512M
    - Definir serviço fluxcp: build docker/fluxcp, porta 80, depends_on mariadb (service_healthy), redes interna+externa, volume fluxcp-data, cpu 0.25 mem 256M
    - Definir serviço autoheal: imagem willfarrell/autoheal:1.2.0 pinada, mount /var/run/docker.sock:ro, env AUTOHEAL_CONTAINER_LABEL=all, cpu 0.1 mem 64M
    - Todos os serviços com restart: unless-stopped, logging json-file max-size 50m max-file 5
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 3.1, 3.2, 3.4, 3.8, 5.1, 6.1, 6.6, 6.7, 8.3, 8.4, 8.5, 9.1, 9.2, 9.3, 9.4, 9.5, 9.6, 9.7, 12.1, 12.2, 13.1, 13.6_

  - [x] 4.2 Criar script wrapper do MariaDB para cálculo dinâmico do buffer pool
    - Criar `docker/mariadb-entrypoint-wrapper.sh` que lê /sys/fs/cgroup/memory.max (cgroups v2) ou /sys/fs/cgroup/memory/memory.limit_in_bytes (v1), calcula 50% para buffer_pool, aplica mínimo 128MB, atualiza custom.cnf via sed, exec docker-entrypoint.sh
    - _Requirements: 3.9, 3.14_

- [x] 5. Checkpoint - Validar Docker Compose
  - Executar `docker compose config --quiet` para validar sintaxe. Ensure all tests pass, ask the user if questions arise.

- [x] 6. Scripts de segurança e provisionamento
  - [x] 6.1 Criar script de provisionamento (setup.sh)
    - Instalar Docker Engine e Docker Compose Plugin via repositório oficial do Docker
    - Instalar e configurar UFW com política default DROP (INPUT e FORWARD), permitir portas: SSH (configurável), 6900, 6121, 5121, 3000, 443, 80
    - Instalar e configurar fail2ban para SSH (maxretry=5, findtime=60, bantime=600)
    - Instalar e configurar unattended-upgrades para patches de segurança automáticos
    - Configurar logrotate para logs do rAthena (7 dias, compressão gzip, diário)
    - Criar diretórios de dados (/opt/rathena/logs/login, /opt/rathena/logs/char, /opt/rathena/logs/map)
    - Implementar detecção de Docker já instalado (skip se funcional — idempotência)
    - Implementar geração de senhas fortes (32 chars alfanuméricos + especiais via openssl rand) quando .env não tem credenciais definidas
    - Implementar validação de senha fraca (warning se <16 chars ou sem caracteres especiais, mas permitir inicialização)
    - _Requirements: 11.1, 11.2, 11.6, 8.2, 8.6, 8.7, 8.9, 12.3_

  - [x] 6.2 Criar script de hardening (hardening.sh)
    - Configurar SSH: PasswordAuthentication no, PermitRootLogin no
    - Configurar sysctl de rede: net.ipv4.tcp_syncookies=1, net.ipv4.conf.all.rp_filter=1, net.ipv4.tcp_max_syn_backlog=2048, desabilitar IPv6 se não utilizado
    - Proteger Docker socket: chmod 660, ownership root:docker
    - Implementar rate limiting iptables nas portas 6900/6121/5121: hashlimit 10 novas conexões/sec por IP (burst 15), connlimit 20 conexões simultâneas por IP, DROP sem resposta
    - Configurar conntrack com timeout reduzido para mitigação SYN flood
    - Remover pacotes desnecessários, configurar limites de arquivo
    - _Requirements: 8.1, 8.4, 8.8, 8.10, 8.11, 14.1, 14.2, 14.3, 14.4_

- [x] 7. Checkpoint - Validar scripts shell
  - Executar `shellcheck scripts/setup.sh scripts/hardening.sh` para validar sintaxe e portabilidade. Ensure all tests pass, ask the user if questions arise.

- [x] 8. Sistema de backup e restauração
  - [x] 8.1 Criar script de backup (scripts/backup/backup.sh)
    - Implementar mariadb-dump com --single-transaction --routines --triggers --events
    - Comprimir com gzip, nomear como rathena_db_YYYY-MM-DD_HHmmss.sql.gz
    - Implementar backup de configurações (conf/ + npc/custom/) em rathena_config_YYYY-MM-DD.tar.gz
    - Implementar rotação: remover backups com mais de 30 dias (find + delete)
    - Armazenar em volume separado (rathena-backups) do volume de dados MariaDB
    - Registrar resultado em log: timestamp, tamanho, duração, sucesso/falha
    - Implementar notificação webhook em caso de falha (código de saída + últimas linhas do log) para Discord/Telegram/Slack
    - _Requirements: 7.1, 7.2, 7.3, 7.4, 7.5, 7.6, 7.9_

  - [x] 8.2 Criar crontab e entrypoint do backup service
    - Criar `scripts/backup/crontab` com job agendado para 04:00 UTC
    - Criar `scripts/backup/entrypoint.sh` que instala o crontab e inicia o cron daemon em foreground
    - _Requirements: 7.1_

  - [x] 8.3 Criar script de restauração (scripts/restore.sh)
    - Aceitar arquivo de backup como argumento
    - Parar serviços rAthena (docker compose stop login-server char-server map-server)
    - Validar arquivo de backup (existência, integridade gzip via gunzip -t)
    - Restaurar banco via gunzip | mariadb
    - Verificar integridade (CHECK TABLE nas tabelas principais: login, char_, inventory, guild)
    - Reiniciar serviços na ordem correta (docker compose up -d login-server char-server map-server)
    - Registrar progresso em log, com estimativa de tempo para bancos >5GB (3 min/GB adicional)
    - RTO target: <15 minutos para bancos até 5GB
    - _Requirements: 7.7, 7.8, 7.11_

- [x] 9. Checkpoint - Validar scripts de backup
  - Executar `shellcheck scripts/backup/backup.sh scripts/backup/entrypoint.sh scripts/restore.sh` para validar. Ensure all tests pass, ask the user if questions arise.

- [x] 10. Monitoramento: Grafana provisioning e dashboards
  - [x] 10.1 Criar datasource provisioning do Grafana
    - Criar `monitoring/grafana/provisioning/datasources/zabbix.yml` com configuração do plugin Zabbix apontando para zabbix-server via API
    - Criar `monitoring/grafana/provisioning/dashboards/dashboards.yml` definindo provider para /var/lib/grafana/dashboards
    - _Requirements: 6.1, 6.2_

  - [x] 10.2 Criar dashboard Server Overview (JSON)
    - Criar `monitoring/grafana/dashboards/server-overview.json` com painéis de status para Login Server (TCP 6900), Char Server (TCP 6121), Map Server (TCP 5121) e MariaDB usando indicadores de status verde/amarelo/vermelho
    - _Requirements: 6.3_

  - [x] 10.3 Criar dashboard Database Performance (JSON)
    - Criar `monitoring/grafana/dashboards/database-performance.json` com métricas: queries por segundo, conexões ativas, uso buffer pool, slow queries, tamanho do banco
    - _Requirements: 6.4_

  - [x] 10.4 Criar dashboard Host Resources (JSON)
    - Criar `monitoring/grafana/dashboards/host-resources.json` com métricas: CPU, memória, disco, rede com granularidade de 1 minuto
    - _Requirements: 6.5_

- [x] 11. Monitoramento: Configuração Zabbix
  - [x] 11.1 Criar template de monitoramento Zabbix (XML/YAML)
    - Criar `monitoring/zabbix/templates/rathena-monitoring.xml` com:
      - Items: monitoramento TCP nas portas 6900, 6121, 5121 (net.tcp.port)
      - Items: métricas de CPU, memória, disco e rede do host via Agent2
      - Items: métricas MariaDB via template "MySQL by Zabbix agent" (conexões ativas, QPS, slow queries, buffer pool)
      - Triggers: CPU >80% por 5min com guard >0% (severidade High)
      - Triggers: memória >85% por 3min (severidade High)
      - Triggers: disco <10% livre (severidade Disaster)
      - Triggers: TCP fail 30s nos serviços rAthena (severidade Disaster)
      - Triggers: slow queries >10/min (severidade Warning)
      - Triggers: backup falhou (severidade High)
    - Configurar retenção: history 90 dias, trends 365 dias por item
    - Configurar media type webhook para notificações (Discord/Telegram/Slack)
    - _Requirements: 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 5.8, 5.9, 5.10_

- [x] 12. Pipeline CI/CD com GitHub Actions
  - [x] 12.1 Criar workflow de validação (validate.yml)
    - Trigger: pull_request (create/update)
    - Steps: hadolint nos Dockerfiles, shellcheck em todos os scripts (setup.sh, hardening.sh, backup.sh, entrypoint.sh, restore.sh), docker compose config --quiet, validação .env.example vs variáveis referenciadas, build de teste das imagens sem push, Trivy scan nas imagens (block CRITICAL/HIGH)
    - _Requirements: 4.1, 4.2, 4.5, 4.6, 4.10_

  - [x] 12.2 Criar workflow de build (build.yml)
    - Trigger: push to main (merge)
    - Steps: build multi-stage com targets login, char, map e fluxcp, tag com SHA curto do commit (ghcr.io/org/rathena-login:sha-abc123, rathena-char:sha-abc123, rathena-map:sha-abc123, rathena-fluxcp:sha-abc123), push para GHCR
    - Secrets: GHCR_TOKEN para push de imagens
    - _Requirements: 4.3, 4.7_

  - [x] 12.3 Criar workflow de deploy (deploy.yml)
    - Trigger: workflow_dispatch (manual)
    - Steps: verificar conexão SSH, executar backup pré-deploy (mariadb-dump), pull novas imagens, docker compose up -d (recreate containers afetados), aguardar healthchecks de todos os serviços
    - Secrets: SSH_PRIVATE_KEY, SERVER_HOST, SERVER_USER
    - _Requirements: 4.4, 4.9_

  - [x] 12.4 Criar workflow de rollback (rollback.yml)
    - Trigger: workflow_dispatch
    - Steps: obter tag do commit anterior (via git log), pull imagens com tag anterior, recreate containers com imagens anteriores
    - _Requirements: 4.8_

- [x] 13. Checkpoint - Validar workflows e CI/CD
  - Validar YAML dos workflows via linting. Verificar que secrets necessários estão documentados. Ensure all tests pass, ask the user if questions arise.

- [x] 14. Logging e configuração de logs
  - [x] 14.1 Criar configuração logrotate para rAthena
    - Criar configuração logrotate (provisionado pelo setup.sh em /etc/logrotate.d/rathena) com rotação diária, retenção 7 dias, compressão gzip, missingok, notifempty
    - Confirmar que logs aplicacionais do rAthena são mapeados para /opt/rathena/logs/{login,char,map} no host via volumes no docker-compose.yml
    - _Requirements: 12.2, 12.3, 12.4_

  - [x] 14.2 Documentar recuperação point-in-time com binary logs
    - Confirmar configuração de log-bin=mysql-bin e expire_logs_days=7 no custom.cnf
    - Documentar procedimento PITR: identificar posição no binlog, aplicar mysqlbinlog --start-position após restore do dump completo
    - Documentar RTO (30min backup completo, 45min com PITR) e RPO (24h backup completo, minutos com binary logs)
    - _Requirements: 7.10, 7.11_

- [x] 15. Documentação operacional
  - [x] 15.1 Criar Runbook operacional (docs/RUNBOOK.md)
    - Seção 1: Tabela de decisão rápida (colunas: sintoma observado, severidade, possíveis causas, comandos de diagnóstico, ação recomendada)
    - Seção 2: Procedimentos por serviço:
      - Login Server (4 cenários: container não inicia, recusa conexões na porta 6900, erro de autenticação de jogadores, falha de conexão com MariaDB)
      - Char Server (4 cenários: não conecta ao Login Server, erro ao carregar dados de personagem, timeout de comunicação, Inter_Server_Password incorreta)
      - Map Server (4 cenários: crash recorrente, lag excessivo/high tick time, desconexão em massa de jogadores, consumo excessivo de memória)
      - MariaDB (5 cenários: container não inicia, corrupção de tabela InnoDB, performance degradada/slow queries, locks excessivos, disco cheio)
    - Seção 3: Operações de rotina — restore de backup completo, atualização do rAthena (verificar CVEs, backup pré-update, pull código, rebuild imagens, deploy com validação, rollback se falha), rollback de deploy
    - Seção 4: Comandos de diagnóstico por categoria — logs de containers (docker compose logs), métricas de sistema (top, df, free), conexões ativas no MariaDB, queries lentas, estado dos healthchecks (docker inspect)
    - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.5, 10.6, 10.7, 10.8_

  - [x] 15.2 Criar documentação de deploy e README
    - Adicionar ao README.md sequência numerada de primeiro deploy: clone repo → executar setup.sh → copiar e editar .env → docker compose up -d → verificar healthchecks → primeiro login de jogador
    - Documentar pré-requisitos mínimos: 4GB RAM, 2 vCPUs, 40GB disco SSD, Ubuntu 24.04 LTS, acesso root ou sudo
    - Documentar recomendações de proteção DDoS L4 específicas para game servers (OVH Game, Hetzner, Path.net)
    - Documentar configuração de rate limit do rAthena (allowed_regs, time_allowed) para limitar tentativas de login por IP
    - Documentar processo de atualização de segurança do rAthena (monitoramento CVEs, procedimento de patch, verificação pós-deploy)
    - _Requirements: 11.4, 11.5, 11.7, 14.5, 14.6, 8.13_

- [x] 16. Final checkpoint - Validação completa
  - Executar hadolint, shellcheck, docker compose config em todo o projeto. Verificar que todas as variáveis do .env.example estão referenciadas nos arquivos de configuração e docker-compose.yml. Ensure all tests pass, ask the user if questions arise.

## Notes

- Esta feature é Infrastructure as Code (IaC) — não se aplica Property-Based Testing
- Validação é feita via linting (hadolint, shellcheck), smoke tests, healthchecks e Trivy scan
- Cada task referencia requisitos específicos para rastreabilidade completa
- Checkpoints garantem validação incremental antes de avançar
- O design especifica tecnologias concretas (Bash, Docker, YAML) — não é pseudocódigo
- Scripts devem ser idempotentes quando possível (setup.sh pode ser re-executado)
- Imagens Docker usam versões pinadas conforme definido no design (sem tag "latest")
- Containers rAthena usam filesystem read-only com tmpfs para segurança
- O Autoheal monitora healthchecks e reinicia containers unhealthy automaticamente

## Task Dependency Graph

```json
{
  "waves": [
    { "id": 0, "tasks": ["1.1", "1.2", "1.3", "1.4"] },
    { "id": 1, "tasks": ["2.1", "2.2", "2.3"] },
    { "id": 2, "tasks": ["4.1", "4.2"] },
    { "id": 3, "tasks": ["6.1", "6.2"] },
    { "id": 4, "tasks": ["8.1", "8.2", "8.3"] },
    { "id": 5, "tasks": ["10.1", "10.2", "10.3", "10.4"] },
    { "id": 6, "tasks": ["11.1"] },
    { "id": 7, "tasks": ["12.1", "12.2", "12.3", "12.4"] },
    { "id": 8, "tasks": ["14.1", "14.2"] },
    { "id": 9, "tasks": ["15.1", "15.2"] }
  ]
}
```
