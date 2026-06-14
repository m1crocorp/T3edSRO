# Runbook Operacional — rAthena Server Infrastructure

> **Nota:** A versão canônica e completa deste runbook está em [`docs/RUNBOOK.md`](docs/RUNBOOK.md).

## Tabela de Decisão Rápida

| Sintoma | Severidade | Possíveis Causas | Diagnóstico | Ação |
|---------|-----------|------------------|-------------|------|
| Jogadores não conseguem logar | Disaster | Login Server down, MariaDB down, firewall bloqueando | `docker compose ps`, `nc -z <ip> 6900` | Reiniciar login-server, verificar MariaDB |
| Jogadores desconectam em massa | Disaster | Map Server crash, rede instável, DDoS | `docker compose logs map-server`, `iftop` | Verificar logs, rate limiting, reiniciar se necessário |
| Lag excessivo no jogo | High | Map Server com CPU/RAM saturada, slow queries | `docker stats`, `docker compose logs map-server \| grep tick` | Verificar recursos, otimizar DB, reiniciar |
| Personagens não carregam | High | Char Server down, erro de banco | `docker compose ps char-server`, logs | Reiniciar char-server, verificar DB |
| Painel web inacessível | Warning | FluxCP down, Apache crash | `docker compose ps fluxcp`, `curl localhost:80` | Reiniciar fluxcp |
| Grafana sem dados | Warning | Zabbix Server down, datasource desconfigurado | `docker compose ps zabbix-server`, testar datasource | Reiniciar zabbix, verificar config |
| Disco quase cheio | Disaster | Logs acumulados, backups não rotacionados, binlogs | `df -h`, `docker system df`, `du -sh /opt/rathena/logs/` | Limpar logs, rotacionar, prune Docker |
| Backup falhou | High | MariaDB indisponível, disco cheio, permissão | `docker compose logs backup`, verificar webhook | Verificar espaço, executar backup manual |
| Alerta de CPU alta | High | Map Server sobrecarregado, mob spawn excessivo | `docker stats --no-stream`, `top` | Verificar scripts NPC, limitar spawn |
| SSH não funciona | High | Fail2ban bloqueou IP, key incorreta, sshd down | `fail2ban-client status sshd`, console do provedor | Desbanir IP, verificar keys |

## Procedimentos por Serviço

### Login Server

#### Cenário 1: Container não inicia

```bash
# Diagnóstico
docker compose ps login-server
docker compose logs login-server --tail 50

# Causas comuns e soluções
# 1. MariaDB não está healthy → aguardar ou reiniciar MariaDB
docker compose ps mariadb
docker compose restart mariadb
# Aguardar healthy, login-server iniciará automaticamente

# 2. Configuração inválida → verificar templates
docker compose exec login-server cat /rathena/conf/generated/login_athena.conf

# 3. Binário corrompido → rebuild da imagem
docker compose build login-server
docker compose up -d login-server
```

#### Cenário 2: Recusa conexões na porta 6900

```bash
# Verificar se o processo está rodando
docker compose exec login-server ps aux | grep login-server

# Verificar se a porta está escutando
docker compose exec login-server ss -tlnp | grep 6900

# Verificar firewall do host
sudo ufw status | grep 6900
sudo iptables -L -n | grep 6900

# Verificar rate limiting (IP pode estar bloqueado)
sudo iptables -L -n | grep hashlimit
```

#### Cenário 3: Erro de autenticação de jogadores

```bash
# Verificar logs de login
docker compose logs login-server --tail 100 | grep -i "auth\|login\|failed"

# Verificar conexão com banco
docker compose exec login-server nc -z mariadb 3306

# Verificar se a conta existe no banco
docker compose exec mariadb mariadb -u root -p -e \
    "SELECT userid, state, unban_time FROM ragnarok.login WHERE userid='<jogador>';"
```

#### Cenário 4: Falha de conexão com MariaDB

```bash
# Verificar se MariaDB está acessível da rede interna
docker compose exec login-server nc -z mariadb 3306

# Verificar credenciais no config gerado
docker compose exec login-server cat /rathena/conf/generated/inter_athena.conf | grep -i "sql"

# Verificar logs do MariaDB
docker compose logs mariadb --tail 30

# Testar conexão diretamente
docker compose exec mariadb mariadb -u rathena -p -e "SELECT 1;"
```

### Char Server

#### Cenário 1: Não conecta ao Login Server

```bash
# Verificar se Login Server está healthy
docker compose ps login-server

# Verificar Inter_Server_Password
docker compose exec char-server cat /rathena/conf/generated/inter_athena.conf | grep "passwd"
docker compose exec login-server cat /rathena/conf/generated/inter_athena.conf | grep "passwd"
# Ambos devem ter o mesmo valor

# Verificar logs de conexão
docker compose logs char-server --tail 30 | grep -i "login\|connect\|auth"

# Solução: reiniciar char-server após login-server estar healthy
docker compose restart char-server
```

#### Cenário 2: Erro ao carregar dados de personagem

```bash
# Verificar logs
docker compose logs char-server --tail 50 | grep -i "char\|load\|error"

# Verificar integridade das tabelas
docker compose exec mariadb mariadb -u root -p -e \
    "CHECK TABLE ragnarok.char_, ragnarok.inventory, ragnarok.storage_;"

# Se tabela corrompida:
docker compose exec mariadb mariadb -u root -p -e \
    "REPAIR TABLE ragnarok.char_;"
```

#### Cenário 3: Timeout de comunicação

```bash
# Verificar latência entre containers
docker compose exec char-server ping -c 5 login-server
docker compose exec char-server ping -c 5 mariadb

# Verificar se rede Docker está saudável
docker network inspect rathena-infra_rathena-internal

# Solução: recrear rede se necessário
docker compose down
docker compose up -d
```

#### Cenário 4: Inter_Server_Password incorreta

```bash
# Sintoma: "Inter-Server Authentication Failed" nos logs
docker compose logs char-server | grep -i "auth.*fail"

# Verificar se todas as configs estão consistentes
for svc in login-server char-server map-server; do
    echo "=== $svc ==="
    docker compose exec $svc cat /rathena/conf/generated/inter_athena.conf | grep "passwd"
done

# Solução: corrigir no .env e reiniciar
nano .env  # Verificar INTER_SERVER_PASSWORD
docker compose up -d  # Regenera configs
```

### Map Server

#### Cenário 1: Crash recorrente

```bash
# Verificar logs do crash
docker compose logs map-server --tail 100 | grep -i "error\|crash\|signal\|segfault"

# Verificar core dumps (se habilitado)
docker compose exec map-server ls -la /tmp/core*

# Verificar se é problema de NPC script
docker compose logs map-server | grep -i "npc\|script\|parse"

# Solução temporária: reiniciar sem scripts custom
# Comentar mount de npc/custom no docker-compose.yml e reiniciar

# Verificar uso de memória (memory leak)
docker stats map-server --no-stream
```

#### Cenário 2: Lag excessivo (high tick time)

```bash
# Verificar tick time nos logs
docker compose logs map-server --tail 100 | grep -i "tick\|lag\|slow"

# Verificar uso de CPU
docker stats map-server --no-stream

# Verificar slow queries do banco
docker compose exec mariadb mariadb -u root -p -e \
    "SHOW FULL PROCESSLIST;" | grep -v Sleep

# Verificar se há mob spawn excessivo
docker compose logs map-server | grep -i "spawn\|mob" | tail -20

# Soluções:
# 1. Aumentar limite de CPU no docker-compose.yml
# 2. Otimizar scripts NPC com muitos timers
# 3. Reduzir spawn rate de mobs
# 4. Reiniciar para limpar estado
docker compose restart map-server
```

#### Cenário 3: Desconexão em massa de jogadores

```bash
# Verificar se é problema de rede
docker compose exec map-server ss -s  # Conexões ativas

# Verificar se é DDoS
sudo iptables -L -n -v | grep DROP  # Pacotes dropados
sudo netstat -an | grep 5121 | wc -l  # Conexões simultâneas

# Verificar logs
docker compose logs map-server --tail 50 | grep -i "disconnect\|timeout\|kicked"

# Se DDoS: verificar rate limiting
sudo iptables -L -n | grep hashlimit

# Se crash interno: reiniciar
docker compose restart map-server
```

#### Cenário 4: Consumo excessivo de memória

```bash
# Verificar uso atual
docker stats map-server --no-stream

# Verificar limites configurados
docker inspect map-server | grep -A5 "Memory"

# Se atingindo o limite (OOM Kill):
docker compose logs map-server | grep -i "oom\|killed\|memory"

# Soluções:
# 1. Aumentar limite de memória no docker-compose.yml
# 2. Verificar scripts NPC com memory leak
# 3. Reiniciar periodicamente (workaround)
docker compose restart map-server
```

### MariaDB

#### Cenário 1: Container não inicia

```bash
# Verificar logs
docker compose logs mariadb --tail 50

# Causas comuns:
# 1. innodb_buffer_pool_size muito grande
docker compose logs mariadb | grep -i "buffer pool"
# Solução: ajustar em db/conf.d/custom.cnf ou variável de ambiente

# 2. Disco cheio
df -h
docker system df

# 3. Volume corrompido
docker compose down
docker volume inspect rathena-infra_rathena-db-data

# 4. Permissões
docker compose exec mariadb ls -la /var/lib/mysql/
```

#### Cenário 2: Corrupção de tabela InnoDB

```bash
# Identificar tabelas corrompidas
docker compose exec mariadb mariadb -u root -p -e \
    "CHECK TABLE ragnarok.login, ragnarok.char_, ragnarok.inventory, ragnarok.storage_;"

# Tentar reparo
docker compose exec mariadb mariadb -u root -p -e \
    "REPAIR TABLE ragnarok.<tabela_corrompida>;"

# Se reparo não funcionar: restaurar do backup
sudo bash scripts/restore.sh /backups/rathena_db_<ultimo>.sql.gz

# Para corrupção grave de InnoDB:
# 1. Parar MariaDB
docker compose stop mariadb

# 2. Adicionar ao custom.cnf temporariamente:
# innodb_force_recovery = 1

# 3. Iniciar, exportar dados, remover volume, reimportar
docker compose start mariadb
docker compose exec mariadb mariadb-dump --all-databases > /tmp/emergency.sql
```

#### Cenário 3: Performance degradada (slow queries)

```bash
# Verificar slow query log
docker compose exec mariadb cat /var/lib/mysql/slow-query.log | tail -50

# Verificar processlist
docker compose exec mariadb mariadb -u root -p -e "SHOW FULL PROCESSLIST;"

# Verificar status do InnoDB
docker compose exec mariadb mariadb -u root -p -e "SHOW ENGINE INNODB STATUS\G"

# Verificar buffer pool hit rate
docker compose exec mariadb mariadb -u root -p -e \
    "SHOW GLOBAL STATUS LIKE 'Innodb_buffer_pool%';"

# Soluções:
# 1. Aumentar innodb_buffer_pool_size se hit rate < 99%
# 2. Adicionar índices nas queries lentas
# 3. Otimizar queries via EXPLAIN
# 4. Verificar se max_connections está saturado
docker compose exec mariadb mariadb -u root -p -e \
    "SHOW GLOBAL STATUS LIKE 'Max_used_connections';"
```

#### Cenário 4: Locks excessivos

```bash
# Verificar locks ativos
docker compose exec mariadb mariadb -u root -p -e \
    "SELECT * FROM information_schema.INNODB_LOCKS;"

# Verificar transações longas
docker compose exec mariadb mariadb -u root -p -e \
    "SELECT * FROM information_schema.INNODB_TRX WHERE trx_started < NOW() - INTERVAL 60 SECOND;"

# Matar query travada
docker compose exec mariadb mariadb -u root -p -e "KILL <process_id>;"
```

#### Cenário 5: Disco cheio

```bash
# Verificar espaço
df -h /var/lib/docker/volumes/

# Verificar tamanho do banco
docker compose exec mariadb mariadb -u root -p -e \
    "SELECT table_schema, ROUND(SUM(data_length + index_length) / 1024 / 1024, 1) AS 'Size (MB)'
     FROM information_schema.tables GROUP BY table_schema;"

# Purgar binary logs antigos
docker compose exec mariadb mariadb -u root -p -e "PURGE BINARY LOGS BEFORE NOW() - INTERVAL 3 DAY;"

# Limpar logs Docker
docker system prune -f
sudo truncate -s 0 /opt/rathena/logs/map/map-server.log

# Rotacionar backups manualmente se necessário
find /backups/ -name "*.sql.gz" -mtime +7 -delete
```

## Operações de Rotina

### Restauração de Backup

```bash
# 1. Listar backups disponíveis
ls -lh /backups/rathena_db_*.sql.gz | tail -10

# 2. Executar restauração
sudo bash scripts/restore.sh /backups/rathena_db_2026-06-14_040000.sql.gz

# 3. Verificar resultado
docker compose ps
docker compose logs login-server --tail 5
```

### Atualização do rAthena

```bash
# 1. Verificar CVEs pendentes
# Acessar: https://github.com/rathena/rathena/security/advisories

# 2. Backup pré-atualização
docker compose exec backup /scripts/backup.sh

# 3. Atualizar código (se build local)
# Editar RATHENA_BRANCH no Dockerfile ou .env
nano .env  # RATHENA_BRANCH=master ou commit específico

# 4. Rebuild imagens
docker compose build --no-cache login-server char-server map-server

# 5. Deploy com validação
docker compose up -d login-server char-server map-server

# 6. Verificar healthchecks
docker compose ps
# Aguardar todos healthy

# 7. Testar funcionalidade
# Login, criar personagem, entrar no jogo

# 8. Rollback se necessário
docker compose down
git checkout HEAD~1 -- Dockerfile
docker compose build
docker compose up -d
```

### Rollback de Deploy

```bash
# Via imagens taggeadas (GHCR)
# 1. Identificar tag anterior
docker compose images | grep rathena

# 2. Atualizar tags no .env
nano .env  # COMMIT_SHA=<sha_anterior>

# 3. Pull e recreate
docker compose pull
docker compose up -d

# Via git (build local)
git log --oneline -5
git checkout <commit_anterior>
docker compose build
docker compose up -d
```

## Comandos de Diagnóstico

### Logs de Containers

```bash
# Todos os serviços
docker compose logs --tail 50

# Serviço específico
docker compose logs login-server --tail 100

# Seguir em tempo real
docker compose logs -f map-server

# Filtrar por padrão
docker compose logs map-server | grep -i "error\|warning" | tail -20

# Logs com timestamp
docker compose logs --timestamps char-server | tail -20
```

### Métricas de Sistema

```bash
# Uso de recursos por container
docker stats --no-stream

# Uso de disco Docker
docker system df -v

# Uso de disco host
df -h

# Memória do host
free -h

# CPU do host
top -bn1 | head -20

# Conexões de rede
ss -tlnp  # Portas escutando
ss -s     # Resumo de conexões
```

### Conexões Ativas no MariaDB

```bash
# Processlist
docker compose exec mariadb mariadb -u root -p -e "SHOW PROCESSLIST;"

# Conexões por usuário
docker compose exec mariadb mariadb -u root -p -e \
    "SELECT user, COUNT(*) as connections FROM information_schema.processlist GROUP BY user;"

# Conexões vs max
docker compose exec mariadb mariadb -u root -p -e \
    "SHOW GLOBAL STATUS LIKE 'Threads_connected';
     SHOW GLOBAL VARIABLES LIKE 'max_connections';"
```

### Queries Lentas

```bash
# Últimas slow queries
docker compose exec mariadb tail -50 /var/lib/mysql/slow-query.log

# Queries em execução agora
docker compose exec mariadb mariadb -u root -p -e \
    "SELECT * FROM information_schema.processlist WHERE time > 5 AND command != 'Sleep';"

# Status geral de queries
docker compose exec mariadb mariadb -u root -p -e \
    "SHOW GLOBAL STATUS LIKE 'Slow_queries';
     SHOW GLOBAL STATUS LIKE 'Questions';
     SHOW GLOBAL STATUS LIKE 'Com_select';"
```

### Estado dos Healthchecks

```bash
# Status de todos os containers
docker compose ps

# Detalhes do healthcheck de um container
docker inspect --format='{{json .State.Health}}' rathena-infra-login-server-1 | jq .

# Testar healthcheck manualmente
docker compose exec login-server nc -z localhost 6900
docker compose exec char-server nc -z localhost 6121
docker compose exec map-server nc -z localhost 5121
docker compose exec mariadb healthcheck.sh --connect --innodb_initialized

# Verificar autoheal
docker compose logs autoheal --tail 20
```

### Rede e Firewall

```bash
# Status UFW
sudo ufw status verbose

# Regras iptables (rate limiting)
sudo iptables -L -n -v | grep hashlimit

# IPs banidos pelo fail2ban
sudo fail2ban-client status sshd

# Desbanir um IP
sudo fail2ban-client set sshd unbanip <IP>

# Conexões por IP (detectar possível DDoS)
sudo ss -tn state established | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -rn | head -20
```
