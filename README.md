# rAthena Server Infrastructure

Infraestrutura de produção completa para servidor privado de Ragnarok Online baseado no emulador [rAthena](https://github.com/rathena/rathena), containerizada via Docker Compose em Ubuntu 24.04 LTS.

## Visão Geral

| Componente | Tecnologia |
|------------|-----------|
| Emulador | rAthena (compilação multi-stage) |
| Orquestração | Docker Compose v2 |
| Banco de Dados | MariaDB 11.4 LTS |
| Monitoramento | Zabbix 7.0 LTS + Grafana 11 |
| CI/CD | GitHub Actions + GHCR |
| Painel Web | FluxCP (PHP 8.2 + Apache) |
| SO Host | Ubuntu 24.04 LTS |

## Pré-requisitos Mínimos

| Recurso | Mínimo | Recomendado |
|---------|--------|-------------|
| **CPU** | 2 vCPUs | 4 vCPUs |
| **RAM** | 4 GB | 8 GB |
| **Disco** | 40 GB SSD | 80 GB SSD |
| **SO** | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS |
| **Acesso** | root ou usuário com sudo | — |
| **Rede** | IP público dedicado | IP com proteção DDoS L4 |

**Portas necessárias** (liberadas no provedor/painel de VPS):

| Porta | Serviço | Direção |
|-------|---------|---------|
| 22 | SSH | Entrada |
| 6900 | Login Server | Entrada |
| 6121 | Char Server | Entrada |
| 5121 | Map Server | Entrada |
| 80 | FluxCP (HTTP) | Entrada |
| 443 | Zabbix Web | Entrada |
| 3000 | Grafana | Entrada |

## Primeiro Deploy (Quick Start)

Siga os passos abaixo em um servidor Ubuntu 24.04 LTS limpo com acesso root ou sudo:

```bash
# 1. Clonar o repositório
git clone https://github.com/m1crocorp/T3edSRO.git
cd T3edSRO

# 2. Executar provisionamento do host (instala Docker, UFW, fail2ban, unattended-upgrades)
sudo bash scripts/setup.sh

# 3. Copiar e editar variáveis de ambiente
cp .env.example .env
nano .env  # Ajustar: senhas do DB, IP público, PACKETVER, nome do servidor

# 4. Subir todos os serviços
docker compose up -d

# 5. Verificar healthchecks (aguarde ~3 minutos para compilação inicial)
docker compose ps
# Todos os serviços devem mostrar status "healthy"

# 6. Verificar logs de inicialização
docker compose logs login-server --tail 20
docker compose logs char-server --tail 20
docker compose logs map-server --tail 20

# 7. Primeiro login de jogador
# 7a. Acesse o FluxCP para criar uma conta: http://<IP-DO-SERVIDOR>/
# 7b. Configure o cliente RO com:
#     - IP do servidor: <IP-DO-SERVIDOR>
#     - PACKETVER: mesmo valor definido no .env (padrão: 20211103)
# 7c. Abra o cliente e faça login com a conta criada
```

> **Nota:** O primeiro `docker compose up -d` pode levar 5-10 minutos pois o rAthena é compilado a partir do código-fonte dentro do container. Builds subsequentes utilizam cache do Docker.

### Troubleshooting do Primeiro Deploy

| Problema | Diagnóstico | Solução |
|----------|-------------|---------|
| Serviço "unhealthy" | `docker compose logs <serviço>` | Verificar logs de erro, confirmar variáveis no .env |
| Erro de conexão DB | `docker compose logs mariadb` | Aguardar inicialização completa do MariaDB |
| Cliente não conecta | Verificar firewall: `sudo ufw status` | Confirmar portas 6900/6121/5121 abertas |
| PACKETVER incompatível | Erro "packet version mismatch" no log | Ajustar PACKETVER no .env e rebuild: `docker compose build` |

## Estrutura do Projeto

```
rathena-infra/
├── docker-compose.yml          # Orquestração de todos os serviços
├── Dockerfile                  # Multi-stage build do rAthena (login/char/map)
├── .env.example                # Template de variáveis de ambiente
├── conf/
│   └── templates/              # Templates de configuração (.tmpl)
│       ├── inter_athena.conf.tmpl
│       ├── login_athena.conf.tmpl
│       ├── char_athena.conf.tmpl
│       └── map_athena.conf.tmpl
├── db/
│   └── conf.d/
│       └── custom.cnf          # Tuning MariaDB
├── docker/
│   ├── entrypoint-login.sh     # Entrypoint Login Server
│   ├── entrypoint-char.sh      # Entrypoint Char Server
│   ├── entrypoint-map.sh       # Entrypoint Map Server
│   ├── mariadb-entrypoint-wrapper.sh  # Buffer pool dinâmico
│   └── fluxcp/
│       └── Dockerfile          # Build FluxCP
├── monitoring/
│   └── grafana/
│       ├── provisioning/
│       │   ├── datasources/
│       │   │   └── zabbix.yml
│       │   └── dashboards/
│       │       └── dashboards.yml
│       └── dashboards/
│           ├── server-overview.json
│           ├── database-performance.json
│           └── host-resources.json
├── npc/
│   └── custom/                 # Scripts NPC customizados
├── scripts/
│   ├── setup.sh                # Provisionamento inicial do host
│   ├── hardening.sh            # Hardening de segurança
│   ├── restore.sh              # Restauração de backup
│   └── backup/
│       ├── backup.sh           # Script de backup diário
│       └── crontab             # Agendamento (04:00 UTC)
├── sql/
│   ├── 00-setup-users.sql      # Criação de usuários e permissões
│   ├── main.sql                # Schema principal rAthena (do repo oficial)
│   └── logs.sql                # Schema de logs rAthena (do repo oficial)
├── .github/
│   └── workflows/
│       ├── validate.yml        # PR: lint + build test + trivy
│       ├── build.yml           # Merge: build + push GHCR
│       ├── deploy.yml          # Manual: deploy ao servidor
│       └── rollback.yml        # Manual: rollback
└── docs/
    ├── ARCHITECTURE.md
    ├── SECURITY.md
    ├── MONITORING.md
    ├── BACKUP_DR.md
    ├── CICD.md
    ├── DEPLOYMENT.md
    └── RUNBOOK.md
```

## Serviços

| Serviço | Porta | Descrição |
|---------|-------|-----------|
| Login Server | 6900 | Autenticação de jogadores |
| Char Server | 6121 | Gerenciamento de personagens |
| Map Server | 5121 | Lógica de jogo (combate, NPCs, mapas) |
| MariaDB | — (interna) | Banco de dados persistente |
| Zabbix Server | — (interna) | Coleta de métricas e alertas |
| Zabbix Web | 443 | Interface web do monitoramento |
| Zabbix Agent2 | — (interna) | Agente de coleta no host |
| Grafana | 3000 | Dashboards de visualização |
| FluxCP | 80 | Painel de controle web para jogadores |
| Backup Service | — (interna) | Backup automatizado diário |
| Autoheal | — | Reinicia containers unhealthy |

## Documentação

| Documento | Conteúdo |
|-----------|----------|
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | Diagrama de arquitetura, componentes, redes e fluxo de dados |
| [SECURITY.md](docs/SECURITY.md) | Hardening, firewall, rate limiting, proteção DDoS |
| [MONITORING.md](docs/MONITORING.md) | Configuração Zabbix, alertas, dashboards Grafana |
| [BACKUP_DR.md](docs/BACKUP_DR.md) | Backup, restauração, RPO/RTO, PITR |
| [CICD.md](docs/CICD.md) | Pipelines GitHub Actions, deploy, rollback |
| [DEPLOYMENT.md](docs/DEPLOYMENT.md) | Guia completo de primeiro deploy |
| [RUNBOOK.md](docs/RUNBOOK.md) | Procedimentos operacionais e tabela de decisão |

## Comandos Úteis

```bash
# Status dos serviços
docker compose ps

# Logs em tempo real
docker compose logs -f login-server char-server map-server

# Reiniciar um serviço específico
docker compose restart map-server

# Backup manual
docker compose exec backup /scripts/backup.sh

# Restaurar backup
sudo bash scripts/restore.sh /path/to/rathena_db_2026-01-15_040000.sql.gz

# Atualizar imagens (após novo build)
docker compose pull && docker compose up -d

# Verificar uso de recursos
docker stats --no-stream
```

## Proteção contra DDoS

Para servidores de jogo online, recomenda-se proteção DDoS Layer 4 adicional além do rate limiting local:

| Provedor | Tipo | Observação |
|----------|------|-----------|
| OVH Game | DDoS Protection inclusa | Servidores dedicados Game com anti-DDoS L4 permanente |
| Hetzner | DDoS Protection básica | Incluída em todos os servidores, proteção até 500 Gbps |
| Path.net | DDoS Mitigation | Especializado em game servers, túnel GRE |

**Recomendação:** Para servidores com 100+ jogadores simultâneos, utilize obrigatoriamente um provedor com proteção L4 nativa. Ataques volumétricos (>1 Gbps) não podem ser mitigados no host — apenas o provedor upstream pode absorver o tráfego antes de atingir o servidor.

O rate limiting local (iptables hashlimit 10 conn/sec por IP + connlimit 20 simultâneas) protege contra ataques de baixo volume e brute-force, mas não substitui proteção de rede upstream contra ataques volumétricos.

## Rate Limiting do rAthena (Login Server)

Além do rate limiting a nível de firewall, o rAthena possui controle interno de tentativas de login no `login_athena.conf`:

```ini
// Número máximo de tentativas de registro/login por janela de tempo
allowed_regs: 5

// Janela de tempo em segundos para o limite acima
time_allowed: 60
```

Estas configurações são definidas via variáveis de ambiente no `.env`:

```bash
# Rate limiting do Login Server (proteção brute-force)
LOGIN_ALLOWED_REGS=5        # Máximo de tentativas por IP na janela
LOGIN_TIME_ALLOWED=60       # Janela de tempo em segundos
```

**Comportamento:** Quando um IP excede `allowed_regs` tentativas em `time_allowed` segundos, o Login Server rejeita novas tentativas desse IP até a janela expirar. Isso previne brute-force de contas sem impactar jogadores legítimos.

**Valores recomendados por cenário:**

| Cenário | allowed_regs | time_allowed | Observação |
|---------|:------------:|:------------:|-----------|
| Produção (padrão) | 5 | 60 | Equilíbrio entre segurança e usabilidade |
| Alta segurança | 3 | 120 | Servidores com histórico de ataques |
| Desenvolvimento | 20 | 10 | Ambiente de testes sem restrição |

## Atualização de Segurança do rAthena

O rAthena, como qualquer software de servidor, pode ter vulnerabilidades descobertas (CVEs). É fundamental manter o emulador atualizado com patches de segurança.

### Monitoramento de CVEs

Acompanhe regularmente as seguintes fontes:

| Fonte | URL | Frequência |
|-------|-----|-----------|
| GitHub Security Advisories | https://github.com/rathena/rathena/security/advisories | Semanal |
| rAthena Commits | https://github.com/rathena/rathena/commits/master | Semanal |
| rAthena Discord / Fórum | Canais oficiais da comunidade | Contínuo |

### Procedimento de Patch

Siga este procedimento ao aplicar uma atualização de segurança:

```bash
# 1. Backup pré-atualização (OBRIGATÓRIO)
docker compose exec backup /scripts/backup.sh

# 2. Atualizar branch/commit no .env (ou Dockerfile ARG)
#    Exemplo: alterar RATHENA_BRANCH para um commit específico com o fix
nano .env
# RATHENA_BRANCH=master  →  RATHENA_BRANCH=<commit-sha-do-patch>

# 3. Rebuild das imagens
docker compose build --no-cache login-server char-server map-server

# 4. Deploy com recreate dos containers afetados
docker compose up -d login-server char-server map-server

# 5. Verificar healthchecks (aguardar ~2-3 min)
docker compose ps
# Confirmar que login-server, char-server e map-server estão "healthy"

# 6. Verificar logs pós-deploy
docker compose logs --tail 50 login-server char-server map-server | grep -i "error\|warning\|fatal"

# 7. Teste funcional: confirmar login de jogador no cliente
```

### Verificação Pós-Deploy

| Verificação | Comando | Resultado Esperado |
|-------------|---------|-------------------|
| Healthchecks | `docker compose ps` | Todos "healthy" |
| Conexão TCP Login | `nc -z localhost 6900` | Sucesso |
| Conexão TCP Char | `nc -z localhost 6121` | Sucesso |
| Conexão TCP Map | `nc -z localhost 5121` | Sucesso |
| Logs sem erros | `docker compose logs --tail 20 \| grep -i error` | Nenhum erro crítico |
| Login de jogador | Testar no cliente RO | Login bem-sucedido |

### Rollback em Caso de Falha

Se o patch introduz regressão (serviço unhealthy, crash, erros de jogadores):

```bash
# Rollback via workflow GitHub Actions
# Ou manualmente:

# 1. Reverter .env para branch/commit anterior
nano .env

# 2. Rebuild com versão anterior
docker compose build --no-cache login-server char-server map-server

# 3. Redeploy
docker compose up -d login-server char-server map-server

# 4. Verificar recuperação
docker compose ps
```

### Registro de Patches Aplicados

Documente cada CVE mitigada no histórico do projeto:

| Data | CVE | Descrição | Commit do Fix |
|------|-----|-----------|---------------|
| — | — | — | — |

> **Recomendação:** Configure um lembrete semanal para verificar o repositório oficial do rAthena por security advisories. Vulnerabilidades críticas (RCE, SQL injection) devem ser aplicadas em até 24 horas após a publicação do fix.

## Arquitetura

Para detalhes completos da arquitetura (diagrama de componentes, redes Docker, fluxo de dados, cadeia de dependências), consulte o documento [ARCHITECTURE.md](ARCHITECTURE.md).

Resumo rápido:
- **11 serviços** orquestrados via Docker Compose
- **2 redes Docker**: interna (isolada) e externa (portas expostas)
- **5 volumes persistentes**: dados MariaDB, backups, Grafana, Zabbix, FluxCP
- **Segurança em camadas**: firewall (UFW) → rate limiting (iptables) → containers read-only → usuário não-root → menor privilégio DB

## Licença

Este projeto de infraestrutura é privado. O emulador rAthena é licenciado sob [GNU GPL v3](https://github.com/rathena/rathena/blob/master/LICENSE).
