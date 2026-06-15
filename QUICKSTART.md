# QUICKSTART — rAthena Server Infrastructure

> **Tipo:** Procedimento  
> **Ambiente:** Ubuntu 24.04 LTS · Docker Compose v2 · rAthena  
> **Audiência:** Administradores de servidor  
> **Última revisão:** Junho 2026  
> **Status:** Validado

---

## Problema / Objetivo

Provisionar e iniciar um servidor rAthena de produção em uma máquina Ubuntu 24.04 LTS nova, incluindo banco de dados, monitoramento, painel web e backup automatizado — pronto para receber jogadores.

---

## Pré-requisitos

| Recurso | Mínimo | Recomendado |
|---------|--------|-------------|
| CPU | 2 vCPUs | 4 vCPUs |
| RAM | 4 GB | 8 GB |
| Disco | 40 GB SSD | 80 GB NVMe |
| SO | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS |
| Acesso | root ou sudo | — |
| Rede | IP público dedicado | IP com proteção DDoS L4 |

**Portas que devem estar liberadas no provedor/painel de VPS:**

| Porta | Serviço |
|-------|---------|
| 22 | SSH |
| 5121 | Map Server |
| 6121 | Char Server |
| 6900 | Login Server |
| 80 | FluxCP (painel web) |
| 443 | Zabbix Web (HTTPS) |
| 3000 | Grafana (dashboards) |

**Você precisará de:**
- Cliente RO compatível com o PACKETVER que vai configurar (padrão: `20211103`)
- Terminal SSH para acessar o servidor

---

## Resolução (Passo a Passo)

### 1. Clonar o repositório

```bash
git clone https://github.com/m1crocorp/T3edSRO.git
cd T3edSRO
```

### 2. Executar provisionamento do host

O script instala Docker, configura firewall (UFW), fail2ban, unattended-upgrades, logrotate e gera senhas fortes automaticamente.

```bash
sudo bash scripts/setup.sh
```

> O script é idempotente — pode ser re-executado sem problemas.

### 3. Baixar schemas SQL do rAthena

O container MariaDB opera em rede isolada (sem acesso à internet). Os schemas devem ser baixados previamente:

```bash
curl -fsSL -o sql/main.sql https://raw.githubusercontent.com/rathena/rathena/master/sql-files/main.sql
curl -fsSL -o sql/logs.sql https://raw.githubusercontent.com/rathena/rathena/master/sql-files/logs.sql
```

> Se o servidor não tem acesso à internet, baixe em outra máquina e copie via `scp`.

### 4. Configurar variáveis de ambiente

```bash
cp .env.example .env
nano .env
```

**Variáveis obrigatórias a ajustar:**

| Variável | O que configurar |
|----------|-----------------|
| `SERVER_PUBLIC_IP` | IP público real do seu servidor |
| `SERVER_NAME` | Nome exibido na lista de servidores do cliente |
| `PACKETVER` | Versão do protocolo do cliente RO (ex: `20211103`) |
| `LOGIN_SERVER_IP` | Usar `rathena-login` (hostname Docker para comunicação inter-server) |
| `CHAR_SERVER_IP` | Usar `rathena-char` (hostname Docker para comunicação inter-server) |

> **Importante:** `LOGIN_SERVER_IP` e `CHAR_SERVER_IP` são endereços de comunicação interna entre os containers. Devem ser os nomes dos containers (`rathena-login`, `rathena-char`), **não** `127.0.0.1`.

> As senhas são geradas automaticamente pelo `setup.sh` se estiverem com valor placeholder.

### 5. Subir todos os serviços

```bash
docker compose up -d
```

> **Tempo esperado:** 5–10 minutos na primeira execução (compilação do rAthena). Builds seguintes usam cache.

### 6. Verificar que tudo está saudável

```bash
docker compose ps
```

**Resultado esperado:** Todos os serviços com status `healthy` ou `running` após ~3 minutos.

### 7. Concluir instalador do FluxCP

No primeiro deploy, o FluxCP precisa criar suas tabelas internas:

1. Acesse `http://<IP-DO-SERVIDOR>/` no navegador
2. O instalador será exibido automaticamente
3. Siga as instruções para criar as tabelas `cp_*`
4. Após conclusão, o painel estará pronto para registro de contas

### 8. Criar conta e testar login

1. Registre uma conta no FluxCP: `http://<IP-DO-SERVIDOR>/`
2. Configure o cliente RO:
   - **IP:** `<IP-DO-SERVIDOR>`
   - **Porta:** `6900`
   - **PACKETVER:** mesmo valor do `.env`
3. Abra o cliente e faça login

---

## Verificação

| Checagem | Comando | Resultado Esperado |
|----------|---------|-------------------|
| Serviços rodando | `docker compose ps` | Todos `healthy` |
| Logs sem erros críticos | `docker compose logs --tail 5 login-server char-server map-server` | Sem `[Fatal Error]` |
| FluxCP acessível | `curl -sL -o /dev/null -w "%{http_code}" http://localhost:80` | `200` |
| Grafana acessível | `curl -s -o /dev/null -w "%{http_code}" http://localhost:3000` | `200` ou `302` |
| Backup programado | `docker compose logs backup --tail 3` | "Next backup in ... seconds" |
| Firewall ativo | `sudo ufw status` | `Status: active` |

---

## Troubleshooting

| Sintoma | Causa Provável | Ação |
|---------|---------------|------|
| Serviço `unhealthy` | Dependência ainda iniciando | Aguardar 3 min; `docker compose logs <serviço>` |
| Char/Map não conectam entre si | IPs inter-server incorretos | Verificar `LOGIN_SERVER_IP=rathena-login` e `CHAR_SERVER_IP=rathena-char` no `.env` |
| `Table doesn't exist` nos logs | Schemas SQL não importados | Verificar se `sql/main.sql` existe; reimportar manualmente se necessário |
| Cliente não conecta | Firewall bloqueando | `sudo ufw status`; liberar portas 6900/6121/5121 |
| "Packet version mismatch" | PACKETVER inconsistente | Ajustar no `.env` e rebuild: `docker compose build` |
| FluxCP mostra "Install & Update" | Primeiro uso | Concluir o instalador do FluxCP (passo 7) |
| Build demora >15 min | Rede lenta para git clone | Usar `RATHENA_BRANCH` com commit específico |

---

## Erros Não-Críticos nos Logs

Os seguintes erros aparecem nos logs mas **não impedem o funcionamento** do servidor:

```
[Error]: File not found: conf/import/packet_conf.txt
[Error]: Failed to open INTER_SERVER_DB database file from 'conf/import/inter_server.yml'
[Error]: Failed to open ATCOMMAND_DB database file from 'conf/import/atcommands.yml'
[Error]: Failed to open PLAYER_GROUP_DB database file from 'conf/import/groups.yml'
[Error]: Failed to open BARTER_DB database file from 'npc/custom/barters.yml'
```

São arquivos de customização opcionais. O servidor funciona com as configurações padrão.

---

## Próximos Passos (Pós-Deploy)

| Ação | Comando / Referência |
|------|---------------------|
| Hardening de segurança | `sudo bash scripts/hardening.sh` |
| Importar template Zabbix | Zabbix Web → Templates → Import: `monitoring/zabbix/templates/rathena-monitoring.xml` |
| Configurar webhook de alertas | Editar `{$ALERT.WEBHOOK.URL}` no template Zabbix |
| NPCs customizados | Colocar em `npc/custom/`; `docker compose restart map-server` |
| Testar backup manual | `docker compose exec backup /scripts/backup.sh` |
| Configurar CI/CD | Secrets no GitHub: `SSH_PRIVATE_KEY`, `SERVER_HOST`, `SERVER_USER`, `GHCR_TOKEN` |

---

## Documentação Relacionada

| Documento | Conteúdo |
|-----------|----------|
| [README.md](README.md) | Visão geral, arquitetura, comandos úteis |
| [DEPLOYMENT.md](DEPLOYMENT.md) | Guia completo de deploy |
| [BACKUP_DR.md](BACKUP_DR.md) | Backup, restauração, PITR |
| [SECURITY.md](SECURITY.md) | Hardening, firewall, rate limiting |
| [MONITORING.md](MONITORING.md) | Zabbix, Grafana, alertas |
| [CICD.md](CICD.md) | Pipelines GitHub Actions |
| [RUNBOOK.md](RUNBOOK.md) | Procedimentos operacionais |
