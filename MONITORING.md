# Monitoramento — rAthena Server Infrastructure

## Visão Geral

O monitoramento utiliza Zabbix 7.0 LTS para coleta de métricas e alertas, com Grafana 11 para visualização via dashboards pré-configurados.

```
Zabbix Agent2 → Zabbix Server → Triggers/Alertas → Webhook (Discord/Telegram/Slack)
                              → Grafana (Dashboards)
```

## Stack de Monitoramento

| Componente | Imagem | Porta | Propósito |
|------------|--------|-------|-----------|
| Zabbix Server | `zabbix/zabbix-server-mysql:7.0-ubuntu-latest` | 10051 (interna) | Processamento de métricas e alertas |
| Zabbix Web | `zabbix/zabbix-web-nginx-mysql:7.0-ubuntu-latest` | 443 (externa) | Interface administrativa |
| Zabbix Agent2 | `zabbix/zabbix-agent2:7.0-ubuntu-latest` | — | Coleta de métricas do host |
| Grafana | `grafana/grafana-oss:11.6.0` | 3000 (externa) | Dashboards de visualização |

## Template Customizado: rAthena Services Monitoring

O template customizado está em `monitoring/zabbix/templates/rathena-monitoring.xml` e pode ser importado via Zabbix Web UI (Configuration → Templates → Import).

### Importação do Template

1. Acesse Zabbix Web: `https://<server-ip>:443`
2. Navegue até **Data collection → Templates**
3. Clique em **Import** (canto superior direito)
4. Selecione o arquivo `monitoring/zabbix/templates/rathena-monitoring.xml`
5. Marque "Create new" para todos os elementos
6. Clique em **Import**
7. Associe o template ao host do servidor rAthena

### Conteúdo do Template

O template `rAthena Services Monitoring` inclui:

**Items (com retenção 90d history / 365d trends):**
- TCP port check para Login Server (porta 6900)
- TCP port check para Char Server (porta 6121)
- TCP port check para Map Server (porta 5121)
- TCP response time para cada serviço

**Triggers:**
- Login/Char/Map Server DOWN (Disaster)
- Disco crítico <10% (Disaster)
- CPU >80% por 5 min (High)
- Memória >85% por 3 min (High)

**Media Type:**
- Webhook configurável para Discord/Telegram/Slack

**Macros configuráveis:**
| Macro | Default | Descrição |
|-------|---------|-----------|
| `{$RATHENA.LOGIN.PORT}` | 6900 | Porta do Login Server |
| `{$RATHENA.CHAR.PORT}` | 6121 | Porta do Char Server |
| `{$RATHENA.MAP.PORT}` | 5121 | Porta do Map Server |
| `{$RATHENA.HOST}` | localhost | Host dos serviços rAthena |
| `{$CPU.THRESHOLD.HIGH}` | 80 | Limiar de CPU (%) |
| `{$MEMORY.THRESHOLD.HIGH}` | 85 | Limiar de memória (%) |
| `{$DISK.THRESHOLD.DISASTER}` | 10 | Limiar de disco livre (%) |
| `{$TCP.FAIL.DURATION}` | 30s | Tempo de falha TCP antes do alerta |
| `{$ALERT.WEBHOOK.URL}` | (vazio) | URL do webhook de notificação |
| `{$ALERT.WEBHOOK.TYPE}` | discord | Tipo: discord, telegram, slack |

## Métricas Coletadas

### Host (via Zabbix Agent2)

- CPU: utilização, load average, iowait
- Memória: utilização, swap, available
- Disco: espaço livre, IOPS, throughput
- Rede: bandwidth in/out, erros, dropped

### Serviços rAthena (via TCP checks)

- Login Server: porta 6900 respondendo (check a cada 10s)
- Char Server: porta 6121 respondendo (check a cada 10s)
- Map Server: porta 5121 respondendo (check a cada 10s)

### MariaDB (via template "MySQL by Zabbix agent")

- Conexões ativas e máximas
- Queries por segundo (QPS)
- Slow queries
- Uso do buffer pool (hit rate)
- Tamanho do banco de dados
- Replication lag (se aplicável)

### Docker Containers (via Zabbix Agent2 + Docker socket)

- Status dos containers (running/stopped/unhealthy)
- Uso de CPU por container
- Uso de memória por container
- Network I/O por container

## Alertas Configurados

### Triggers de Severidade

| Trigger | Condição | Severidade | Notificação |
|---------|----------|-----------|-------------|
| CPU alta | >80% por 5 min (descarta leituras 0%) | High | Webhook |
| Memória alta | >85% por 3 min | High | Webhook |
| Disco crítico | <10% livre | Disaster | Webhook |
| Login Server down | TCP 6900 fail por 30s | Disaster | Webhook |
| Char Server down | TCP 6121 fail por 30s | Disaster | Webhook |
| Map Server down | TCP 5121 fail por 30s | Disaster | Webhook |
| MariaDB slow queries | >10 slow/min | Warning | Log apenas |
| Backup falhou | Exit code != 0 | High | Webhook |

### Detalhes dos Triggers

#### CPU >80% por 5 minutos (High)

```
Expression: min(/rAthena Services/system.cpu.util[,idle],5m)<20 and min(/rAthena Services/system.cpu.util[,idle],5m)>0
```

- Verifica que a CPU idle ficou abaixo de 20% (ou seja, utilização >80%) por 5 minutos contínuos
- **Descarta leituras de 0%**: A condição `>0` garante que leituras inválidas ou zeradas não disparam falsos positivos
- Severidade: **High**
- Ação: Notificação via webhook

#### Memória >85% por 3 minutos (High)

```
Expression: min(/rAthena Services/vm.memory.utilization,3m)>85
```

- Verifica utilização de memória acima de 85% por 3 minutos contínuos
- Severidade: **High**
- Ação: Notificação via webhook

#### Disco <10% livre (Disaster)

```
Expression: last(/rAthena Services/vfs.fs.size[/,pfree])<10
```

- Verifica espaço livre no filesystem raiz
- Severidade: **Disaster** — ação imediata necessária
- Impacto: Backups e escritas no banco podem falhar
- Ação: Notificação via webhook + intervenção manual

#### TCP Fail 30s nos serviços rAthena (Disaster)

```
Expression: max(/rAthena Services/net.tcp.service[tcp,{HOST},{PORT}],30s)=0
```

- Verifica se o serviço não respondeu em nenhuma checagem nos últimos 30 segundos
- Aplicado individualmente a: Login (6900), Char (6121), Map (5121)
- Severidade: **Disaster** — jogadores não conseguem conectar
- Ação: Notificação via webhook + verificar autoheal + runbook

## Configuração de Notificação via Webhook

### Visão Geral

Notificações são enviadas via webhook para alertas de severidade **High** e **Disaster**. O template inclui um media type com script JavaScript que formata a mensagem para cada plataforma.

### Configuração no .env

```env
# Webhook para alertas (Discord, Telegram ou Slack)
ALERT_WEBHOOK_URL=https://discord.com/api/webhooks/xxx/yyy
ALERT_WEBHOOK_TYPE=discord  # discord, telegram, slack
```

### Discord

1. No servidor Discord, crie um webhook: Server Settings → Integrations → Webhooks → New Webhook
2. Copie a URL do webhook
3. Configure no `.env`:

```env
ALERT_WEBHOOK_URL=https://discord.com/api/webhooks/ID/TOKEN
ALERT_WEBHOOK_TYPE=discord
```

Os alertas são enviados como embeds coloridos:
- 🔴 Vermelho para Disaster
- 🟠 Laranja para High
- 🟡 Amarelo para Warning

### Telegram

1. Crie um bot via [@BotFather](https://t.me/BotFather)
2. Obtenha o token do bot
3. Adicione o bot ao grupo/canal desejado
4. Obtenha o chat_id do grupo
5. Configure no `.env`:

```env
ALERT_WEBHOOK_URL=https://api.telegram.org/botTOKEN/sendMessage
ALERT_WEBHOOK_TYPE=telegram
ALERT_TELEGRAM_CHAT_ID=-123456789
```

### Slack

1. Crie um Incoming Webhook: Apps → Incoming Webhooks → Add to Slack
2. Selecione o canal de destino
3. Copie a URL do webhook
4. Configure no `.env`:

```env
ALERT_WEBHOOK_URL=https://hooks.slack.com/services/T00/B00/xxx
ALERT_WEBHOOK_TYPE=slack
```

### Configuração no Zabbix Web UI

Após importar o template, configure o media type:

1. **Administration → Media types** → "rAthena Alert Webhook" (importado do template)
2. Verifique os parâmetros: `webhook_url` e `webhook_type` usam as macros do host
3. **Administration → Users → Admin → Media** → Adicione "rAthena Alert Webhook"
4. Configure severidades: marque "High" e "Disaster"
5. **Configuration → Actions → Trigger actions** → Crie uma action:
   - Nome: "Notify on High/Disaster"
   - Conditions: Trigger severity >= High
   - Operations: Send to Admin via "rAthena Alert Webhook"

### Testando o Webhook

```bash
# Via Zabbix Web UI:
# Administration → Media types → rAthena Alert Webhook → Test

# Ou via curl (Discord):
curl -X POST "$ALERT_WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d '{"embeds":[{"title":"⚠️ Test Alert","description":"Zabbix webhook test","color":16744448}]}'
```

## Retenção de Dados

| Tipo | Período | Propósito |
|------|---------|-----------|
| History (dados brutos) | 90 dias | Análise detalhada recente |
| Trends (agregados) | 365 dias | Tendências de longo prazo |

A retenção é configurada por item no template Zabbix. Todos os items do template `rAthena Services Monitoring` estão configurados com:
- `<history>90d</history>` — dados brutos mantidos por 90 dias
- `<trends>365d</trends>` — dados agregados (min/max/avg por hora) mantidos por 365 dias

Dados mais antigos que o período de retenção são automaticamente purgados pelo Zabbix housekeeper.

### Impacto no Armazenamento

Estimativa para o template rAthena (6 items, check a cada 10s):
- History: ~6 items × 8640 valores/dia × 90 dias × ~50 bytes = ~230 MB
- Trends: ~6 items × 24 registros/dia × 365 dias × ~128 bytes = ~7 MB

O template "MySQL by Zabbix agent" adiciona aproximadamente mais 300 MB ao history.

## Monitoramento MariaDB — Template "MySQL by Zabbix agent"

### Visão Geral

O monitoramento do MariaDB utiliza o template oficial **"MySQL by Zabbix agent"** que já vem incluído no Zabbix 7.0. Este template coleta métricas detalhadas via queries ao MariaDB.

### Configuração

#### 1. Criar usuário de monitoramento no MariaDB

O usuário `zabbix` já existe (criado pelo `sql/00-setup-users.sql`) com acesso ao banco `zabbix`. Para monitoramento do MariaDB é necessário um usuário com acesso de leitura às variáveis de status:

```sql
-- Adicionar ao sql/00-setup-users.sql ou executar manualmente:
CREATE USER IF NOT EXISTS 'zbx_monitor'@'%' IDENTIFIED BY '${ZBX_MONITOR_PASSWORD}';
GRANT USAGE, REPLICATION CLIENT, PROCESS ON *.* TO 'zbx_monitor'@'%';
FLUSH PRIVILEGES;
```

#### 2. Configurar o Zabbix Agent2

O Zabbix Agent2 precisa de configuração para conectar ao MariaDB. No `docker-compose.yml`, passe as variáveis via environment:

```yaml
zabbix-agent2:
  environment:
    - ZBX_ACTIVESERVERS=zabbix-server
  volumes:
    - /var/run/docker.sock:/var/run/docker.sock:ro
```

Crie um arquivo de configuração MySQL para o agent (`/etc/zabbix/zabbix_agent2.d/plugins.d/mysql.conf`):

```ini
Plugins.Mysql.Sessions.rathena.Uri=tcp://mariadb:3306
Plugins.Mysql.Sessions.rathena.User=zbx_monitor
Plugins.Mysql.Sessions.rathena.Password=${ZBX_MONITOR_PASSWORD}
```

#### 3. Vincular o template ao host no Zabbix

1. Acesse **Zabbix Web → Data collection → Hosts**
2. Selecione o host do servidor
3. Em **Templates**, adicione: `MySQL by Zabbix agent`
4. Configure as macros do host:
   - `{$MYSQL.DSN}`: `tcp://mariadb:3306`
   - `{$MYSQL.USER}`: `zbx_monitor`
   - `{$MYSQL.PASSWORD}`: senha do zbx_monitor

#### 4. Métricas disponíveis

O template "MySQL by Zabbix agent" coleta automaticamente:

| Métrica | Item Key | Descrição |
|---------|----------|-----------|
| Uptime | `mysql.uptime` | Tempo desde último restart |
| Queries per second | `mysql.queries` | Total de queries executadas |
| Slow queries | `mysql.slow_queries` | Queries lentas (>2s conforme long_query_time) |
| Connections | `mysql.threads_connected` | Conexões ativas no momento |
| Buffer pool utilization | `mysql.innodb_buffer_pool_utilization` | % do buffer pool em uso |
| Buffer pool hit rate | `mysql.innodb_buffer_pool_read_hit_rate` | Cache hit ratio |
| Table locks waited | `mysql.table_locks_waited` | Locks aguardando |
| Bytes sent/received | `mysql.bytes_sent`, `mysql.bytes_received` | Throughput de rede |
| Database size | `mysql.db.size[ragnarok]` | Tamanho do banco em bytes |

#### 5. Triggers incluídos no template MySQL

O template oficial inclui triggers pré-configurados:

| Trigger | Condição | Severidade |
|---------|----------|-----------|
| MySQL is down | Conexão falhou | High |
| Too many connections | >80% de max_connections | Warning |
| Slow queries rate high | >10 slow queries/min | Warning |
| Replication lag | Lag > threshold | Warning |
| InnoDB buffer pool hit rate low | <95% | Warning |

### Trigger customizado: Slow Queries >10/min

Para complementar o template oficial com o threshold do design (>10 slow queries por minuto):

Crie no Zabbix Web → Configuration → Hosts → Triggers:
```
Name: MariaDB slow queries rate high (>10/min)
Expression: change(/host/mysql.slow_queries)>10
Severity: Warning
```

## Dashboards Grafana

### Provisioning Automático

Dashboards são provisionados automaticamente na inicialização do container Grafana via:
- `monitoring/grafana/provisioning/datasources/zabbix.yml` — Conexão ao Zabbix
- `monitoring/grafana/provisioning/dashboards/dashboards.yml` — Provider de dashboards
- `monitoring/grafana/dashboards/*.json` — Dashboards em formato JSON

### Dashboard: Server Overview

Visão geral de todos os serviços com indicadores de status:

| Painel | Indicador |
|--------|-----------|
| Login Server | 🟢 Online / 🟡 Degraded / 🔴 Offline |
| Char Server | 🟢 Online / 🟡 Degraded / 🔴 Offline |
| Map Server | 🟢 Online / 🟡 Degraded / 🔴 Offline |
| MariaDB | 🟢 Online / 🟡 Degraded / 🔴 Offline |
| Uptime | Tempo desde último restart de cada serviço |
| Players Online | Conexões ativas no Map Server |

### Dashboard: Database Performance

Métricas de banco de dados em tempo real:

- Queries por segundo (SELECT, INSERT, UPDATE, DELETE)
- Conexões ativas vs max_connections
- Buffer pool hit rate (%)
- Slow queries por minuto
- Tamanho total do banco (MB)
- Lock waits e deadlocks

### Dashboard: Host Resources

Métricas de infraestrutura com granularidade de 1 minuto:

- CPU utilization (%) — gráfico temporal
- Memory usage (GB) — gráfico temporal + gauge
- Disk usage (%) — gauge com threshold
- Network throughput (Mbps) — in/out separados
- Disk IOPS — read/write

## Acesso

### Grafana

- **URL**: `http://<server-ip>:3000`
- **Credenciais**: Definidas no `.env` (`GF_SECURITY_ADMIN_USER`, `GF_SECURITY_ADMIN_PASSWORD`)
- **Datasource**: Zabbix (provisionado automaticamente)

### Zabbix Web

- **URL**: `https://<server-ip>:443`
- **Credenciais padrão**: `Admin` / senha definida no `.env` (`ZABBIX_ADMIN_PASSWORD`)
- **TLS**: Via certificado montado em volume ou proxy reverso

## Banco de Dados do Zabbix

O Zabbix utiliza o mesmo container MariaDB do rAthena, mas com banco de dados isolado (`zabbix`). O usuário `zabbix` tem ALL PRIVILEGES apenas no banco `zabbix`, sem acesso ao banco `ragnarok`.

Isso evita o overhead de um segundo container MariaDB enquanto mantém isolamento lógico completo.

## Troubleshooting

### Grafana não exibe dados

1. Verificar se Zabbix Server está healthy: `docker compose ps zabbix-server`
2. Verificar datasource: Grafana → Configuration → Data Sources → Zabbix → Test
3. Verificar logs: `docker compose logs grafana --tail 50`

### Alertas não são enviados

1. Verificar configuração do webhook no Zabbix Web → Administration → Media types
2. Testar webhook manualmente: Zabbix Web → Administration → Media types → Test
3. Verificar logs do Zabbix Server: `docker compose logs zabbix-server | grep "webhook"`
4. Verificar se a macro `{$ALERT.WEBHOOK.URL}` está preenchida no host

### Métricas de container em 0%

Verificar se o Zabbix Agent2 tem acesso ao Docker socket:
```bash
docker compose exec zabbix-agent2 ls -la /var/run/docker.sock
```
O socket deve ser montado como read-only (`/var/run/docker.sock:/var/run/docker.sock:ro`).

### Template não aparece após import

1. Verificar que o arquivo XML é válido: `xmllint --noout monitoring/zabbix/templates/rathena-monitoring.xml`
2. Verificar versão do Zabbix (requer 7.0+)
3. Tentar import via API:
```bash
curl -X POST "https://<server-ip>/api_jsonrpc.php" \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "method": "configuration.import",
    "params": {
      "format": "xml",
      "source": "<conteúdo do XML>",
      "rules": {
        "templates": {"createMissing": true, "updateExisting": true},
        "triggers": {"createMissing": true, "updateExisting": true}
      }
    },
    "auth": "<auth_token>",
    "id": 1
  }'
```

### MariaDB monitoring não funciona

1. Verificar se o usuário `zbx_monitor` existe:
```bash
docker compose exec mariadb mariadb -uroot -p -e "SELECT user, host FROM mysql.user WHERE user='zbx_monitor';"
```
2. Testar conexão do agent:
```bash
docker compose exec zabbix-agent2 zabbix_agent2 -t mysql.ping[tcp://mariadb:3306,zbx_monitor,<password>]
```
3. Verificar logs do agent: `docker compose logs zabbix-agent2 | grep -i mysql`
