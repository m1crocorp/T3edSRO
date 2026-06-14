# Arquitetura — rAthena Server Infrastructure

## Visão Geral

A infraestrutura segue uma arquitetura single-host containerizada com isolamento de rede, onde todos os serviços são orquestrados via Docker Compose em Ubuntu 24.04 LTS.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                            Ubuntu 24.04 LTS                                  │
│                                                                              │
│  ┌────────────────────────────────────────────────────────────────────────┐  │
│  │                        Docker Engine                                    │  │
│  │                                                                         │  │
│  │  ┌──────────────── Rede Externa ────────────────────────────────────┐  │  │
│  │  │  Login:6900  Char:6121  Map:5121  Grafana:3000  Zabbix:443  CP:80│  │  │
│  │  └──────────────────────────────────────────────────────────────────┘  │  │
│  │                                                                         │  │
│  │  ┌──────────────── Rede Interna (isolada) ──────────────────────────┐  │  │
│  │  │  MariaDB  ZabbixServer  ZabbixAgent  BackupService  FluxCP       │  │  │
│  │  └──────────────────────────────────────────────────────────────────┘  │  │
│  │                                                                         │  │
│  │  [Autoheal] — monitora healthchecks via Docker socket                  │  │
│  └────────────────────────────────────────────────────────────────────────┘  │
│                                                                              │
│  [UFW Firewall] → [Fail2ban] → [iptables Rate Limiting]                     │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Decisões Arquiteturais

| Decisão | Escolha | Justificativa |
|---------|---------|---------------|
| Orquestração | Docker Compose v2 | Simplicidade para single-host, declarativo, sem overhead de Kubernetes |
| Imagem base | `debian:bookworm-slim` | Compatibilidade com libs do rAthena, ~80MB, pacotes atualizados |
| Banco de dados | MariaDB 11.4 LTS | Suporte estendido, 100% compatível com rAthena |
| Monitoramento | Zabbix 7.0 LTS + Grafana 11 | Enterprise-grade, templates prontos, alertas nativos com webhook |
| Web Panel | FluxCP (PHP 8.2 + Apache) | Painel oficial da comunidade rAthena |
| CI/CD | GitHub Actions | Integração nativa com GHCR, sem custo para repos públicos |
| Backup | Container dedicado com cron | Isolamento de responsabilidade, agendamento simples |
| Auto-recovery | Autoheal + restart policy | Reinício automático de containers unhealthy |

## Componentes

### Servidores rAthena

Os três serviços do rAthena são compilados a partir de um único Dockerfile multi-stage com targets distintos:

- **Login Server** — Autenticação de contas, porta 6900. Primeiro ponto de contato do cliente RO.
- **Char Server** — Gerenciamento de personagens, guilds e storage, porta 6121. Conecta-se ao Login Server via Inter_Server_Password.
- **Map Server** — Lógica de jogo completa (combate, NPCs, mapas), porta 5121. Maior consumo de recursos (2 CPU, 2GB RAM). Conecta-se ao Char Server.

### Cadeia de Dependências

```
MariaDB (healthy) → Login Server (healthy) → Char Server (healthy) → Map Server
                  → Zabbix Server (healthy) → Zabbix Web
                                             → Zabbix Agent (started)
                                             → Grafana
                  → FluxCP
```

Todos os serviços usam `depends_on` com `condition: service_healthy` para garantir ordem de inicialização correta.

### Banco de Dados

MariaDB 11.4 LTS em container dedicado na rede interna (sem port binding no host):

- Volume nomeado para persistência (`rathena-db-data`)
- Inicialização automática via `/docker-entrypoint-initdb.d/` (schema rAthena + users)
- Buffer pool dinâmico (50% da RAM do container, mínimo 128MB)
- Binary logging habilitado para PITR
- Slow query log para diagnóstico de performance
- 4 usuários com menor privilégio: `rathena`, `rathena_backup`, `fluxcp`, `zabbix`

### Monitoramento

- **Zabbix Server** — Coleta métricas via Agent2, executa triggers e envia alertas
- **Zabbix Agent2** — Coleta métricas do host e containers (via Docker socket)
- **Zabbix Web** — Interface administrativa (HTTPS na porta 443)
- **Grafana** — 3 dashboards provisionados automaticamente: Server Overview, Database Performance, Host Resources

### Backup

Container dedicado com cron (04:00 UTC diário):
- `mariadb-dump` com `--single-transaction --routines --triggers --events`
- Compressão gzip, retenção 30 dias, rotação automática
- Backup separado de configurações (conf/ + npc/custom/)
- Notificação webhook em caso de falha

### Segurança (Camadas)

1. **Rede (Host)** — UFW default DROP, Fail2ban para SSH, iptables rate limiting
2. **Container** — Usuário não-root, filesystem read-only, limites de CPU/RAM, rede isolada
3. **Aplicação** — Inter_Server_Password forte, menor privilégio no DB, senhas geradas (32 chars)
4. **Host OS** — SSH apenas por chave, unattended-upgrades, Docker socket protegido

## Redes Docker

| Rede | Tipo | Propósito |
|------|------|-----------|
| `rathena-internal` | bridge, internal: true | Comunicação entre serviços, sem acesso externo |
| `rathena-external` | bridge | Portas expostas ao host para jogadores e admins |

**Serviços em ambas as redes:** Login Server, Char Server, Map Server, FluxCP, Zabbix Web, Grafana

**Serviços apenas na interna:** MariaDB, Zabbix Server, Zabbix Agent2, Backup Service

## Volumes Persistentes

| Volume | Serviço | Dados |
|--------|---------|-------|
| `rathena-db-data` | MariaDB | Todos os dados do jogo e logs |
| `rathena-backups` | Backup Service | Dumps SQL e configs comprimidos |
| `grafana-data` | Grafana | Dashboards customizados e configurações |
| `zabbix-server-data` | Zabbix Server | Dados internos do Zabbix |
| `fluxcp-data` | FluxCP | Dados do painel web |

## Limites de Recursos

| Serviço | CPU | Memória | Justificativa |
|---------|-----|---------|---------------|
| Login Server | 0.5 | 512 MB | Baixo uso, apenas autenticação |
| Char Server | 0.5 | 512 MB | Moderado, gerenciamento de chars |
| Map Server | 2.0 | 2048 MB | Alto, toda lógica de jogo |
| MariaDB | 1.0 | 2048 MB | Queries constantes, buffer pool |
| Zabbix Server | 0.5 | 1024 MB | Processamento de métricas |
| Zabbix Web | 0.25 | 512 MB | Apenas interface web |
| Zabbix Agent2 | 0.25 | 256 MB | Coleta leve de métricas |
| Grafana | 0.5 | 512 MB | Renderização de dashboards |
| Backup Service | 0.25 | 512 MB | Uso esporádico (1x/dia) |
| FluxCP | 0.25 | 256 MB | PHP leve, poucas requisições |
| Autoheal | 0.1 | 64 MB | Apenas monitora Docker socket |

**Total**: ~6.1 CPU, ~8.25 GB RAM (dentro dos 4GB mínimos com overcommit, recomendado 8GB para produção)

## Logging

### Logs Aplicacionais do rAthena

Os logs gerados pelos servidores rAthena dentro dos containers são persistidos no host via bind mounts:

| Container | Caminho no Container | Caminho no Host |
|-----------|---------------------|-----------------|
| Login Server | `/rathena/log/` | `/opt/rathena/logs/login/` |
| Char Server | `/rathena/log/` | `/opt/rathena/logs/char/` |
| Map Server | `/rathena/log/` | `/opt/rathena/logs/map/` |

Esses diretórios são criados automaticamente pelo script `setup.sh` com owner `1000:1000` (usuário rathena dentro dos containers).

### Rotação de Logs (logrotate)

O `setup.sh` provisiona a configuração `/etc/logrotate.d/rathena` no host com:

- **Rotação**: diária
- **Retenção**: 7 dias
- **Compressão**: gzip (`.gz`)
- **Opções**: `missingok`, `notifempty`, `dateext`
- **Postrotate**: envia `USR1` aos containers para reabrir descritores de arquivo

### Logs de Container (Docker)

Além dos logs aplicacionais, todos os containers geram logs via Docker logging driver (`json-file`), configurados com:

- `max-size: 50m` — rotação automática ao atingir 50 MB
- `max-file: 5` — mantém até 5 arquivos de log rotacionados

Esses logs são acessíveis via `docker compose logs <serviço>`.

## Fluxo de Dados

```
Jogador → [UFW/iptables] → Login Server → MariaDB (autenticação)
                          → Char Server → MariaDB (dados de personagem)
                          → Map Server → MariaDB (estado do jogo)

Admin → [UFW] → Grafana (dashboards)
              → Zabbix Web (alertas)
              → FluxCP (gerenciamento)
              → SSH (acesso direto)
```
