# Runbook Operacional — rAthena Server Infrastructure

> **Versão:** 1.0  
> **Última atualização:** 2025  
> **Ambiente:** Docker Compose / Ubuntu 24.04 LTS  
> **Monitoramento:** Zabbix 7.0 + Grafana 11

---

## Seção 1: Tabela de Decisão Rápida

| Sintoma | Severidade | Causas Possíveis | Diagnóstico | Ação |
|---------|-----------|------------------|-------------|------|
| Jogadores não conseguem logar | **Disaster** | Login Server down, MariaDB down, firewall bloqueando porta 6900 | `docker compose ps login-server`, `nc -z localhost 6900`, `sudo ufw status` | Reiniciar login-server; verificar MariaDB; verificar UFW |
| Jogadores desconectam em massa | **Disaster** | Map Server crash, rede instável, ataque DDoS | `docker compose logs map-server --tail 50`, `ss -s`, `iptables -L -n -v` | Verificar logs crash; verificar rate limiting; reiniciar map-server |
| Lag excessivo no jogo | **High** | Map Server com CPU/RAM saturada, slow queries, NPC scripts pesados | `docker stats map-server`, `docker compose logs map-server \| grep tick` | Verificar recursos; otimizar DB; reiniciar map-server |
| Personagens não carregam | **High** | Char Server down, tabelas corrompidas, MariaDB lento | `docker compose ps char-server`, `docker compose logs char-server` | Reiniciar char-server; CHECK TABLE; verificar DB |
| Char Server não conecta ao Login | **High** | Login Server down, Inter_Server_Password incorreta, rede Docker | `docker compose logs char-server \| grep auth`, verificar configs | Verificar password; reiniciar cadeia login→char→map |
| Map Server crash recorrente | **High** | NPC script inválido, memory leak, OOM Kill | `docker compose logs map-server \| grep segfault`, `docker stats` | Isolar NPC custom; aumentar memory limit; rebuild |
| MariaDB não inicia | **Disaster** | Disco cheio, buffer_pool_size excessivo, volume corrompido | `docker compose logs mariadb`, `df -h`, verificar custom.cnf | Liberar disco; ajustar buffer_pool; recovery mode |
| Corrupção InnoDB | **Disaster** | Shutdown abrupto, disco com bad sectors, OOM | `CHECK TABLE`, `SHOW ENGINE INNODB STATUS` | innodb_force_recovery; export + reimport; restaurar backup |
| Slow queries acumulando | **High** | Falta de índices, buffer_pool baixo, locks longos | `tail slow-query.log`, `SHOW PROCESSLIST` | Adicionar índices; aumentar buffer_pool; KILL queries |
| Locks excessivos no MariaDB | **High** | Transações longas, deadlocks, backup em andamento | `INNODB_TRX`, `INNODB_LOCKS` | KILL transação; aguardar backup; otimizar queries |
| Disco cheio | **Disaster** | Logs acumulados, binlogs, backups não rotacionados | `df -h`, `docker system df`, `du -sh /opt/rathena/logs/` | Purgar binlogs; prune Docker; rotacionar logs |
| Backup falhou | **High** | MariaDB indisponível, disco cheio, permissão negada | `docker compose logs backup`, verificar webhook notificação | Verificar espaço; executar backup manual |
| Painel web (FluxCP) inacessível | **Warning** | Container FluxCP down, Apache crash, MariaDB indisponível | `docker compose ps fluxcp`, `curl -s localhost:80` | Reiniciar fluxcp; verificar MariaDB |
| Grafana sem dados | **Warning** | Zabbix Server down, datasource desconfigurado | `docker compose ps zabbix-server`, verificar datasource Grafana | Reiniciar zabbix-server; reconfigurar datasource |
| Alerta CPU >80% | **High** | Map Server sobrecarregado, mob spawn excessivo, NPC loops | `docker stats --no-stream`, `top -bn1` | Verificar scripts NPC; limitar spawn; aumentar CPU limit |
| SSH não funciona | **High** | Fail2ban bloqueou IP, chave incorreta, sshd down | `fail2ban-client status sshd`, console do provedor | Desbanir IP; verificar authorized_keys |
| Erro autenticação jogadores | **High** | Conta bloqueada, banco corrompido, login-server com bug | `docker compose logs login-server \| grep auth`, consultar tabela login | Verificar state da conta; desbanir; reiniciar |

---

## Seção 2: Procedimentos por Serviço

### 2.1 Login Server (porta 6900)

#### Cenário 1: Container não inicia

**Sintomas:** `docker compose ps` mostra login-server como "Exit" ou "Restarting"

```bash
# 1. Verificar status e logs
docker compose ps login-server
docker compose logs login-server --tail 50

# 2. Verificar se MariaDB está healthy (dependência)
docker compose ps mariadb
# Se mariadb não está healthy, resolver MariaDB primeiro

# 3. Verificar se configuração foi gerada corretamente
docker compose run --rm login-server cat /rathena/conf/generated/login_athena.conf
docker compose run --rm login-server cat /rathena/conf/generated/inter_athena.conf

# 4. Verificar variáveis de ambiente
docker compose config login-server | grep -A20 "environment"

# 5. Verificar binário
docker compose run --rm login-server ls -la /rathena/login-server
```

**Resolução:**

| Causa | Ação |
|-------|------|
| MariaDB não está healthy | `docker compose restart mariadb` → aguardar healthy |
| Config com placeholder não substituído | Verificar .env; corrigir variáveis; `docker compose up -d login-server` |
| Binário corrompido | `docker compose build --no-cache login-server && docker compose up -d login-server` |
| Porta 6900 já em uso no host | `ss -tlnp \| grep 6900`; matar processo conflitante |

#### Cenário 2: Recusa conexões na porta 6900

**Sintomas:** Jogadores recebem "Unable to connect to server"; `nc -z localhost 6900` falha

```bash
# 1. Verificar se o processo login-server está rodando dentro do container
docker compose exec login-server ps aux | grep login-server

# 2. Verificar se a porta está escutando dentro do container
docker compose exec login-server ss -tlnp | grep 6900

# 3. Verificar mapeamento de porta no host
docker port $(docker compose ps -q login-server) 6900

# 4. Verificar firewall do host
sudo ufw status | grep 6900
sudo iptables -L INPUT -n -v | grep 6900

# 5. Verificar rate limiting (IP pode estar bloqueado por hashlimit)
sudo iptables -L -n | grep hashlimit
# Se IP legítimo bloqueado, aguardar expiração ou flush temporário
```

**Resolução:**

| Causa | Ação |
|-------|------|
| Processo não rodando | `docker compose restart login-server` |
| Porta não mapeada | `docker compose down login-server && docker compose up -d login-server` |
| UFW bloqueando | `sudo ufw allow 6900/tcp` |
| Rate limiting bloqueou IP legítimo | Aguardar expiração ou ajustar regra hashlimit |

#### Cenário 3: Erro de autenticação de jogadores

**Sintomas:** Jogadores digitam senha correta mas recebem "Rejected from server"

```bash
# 1. Verificar logs de autenticação
docker compose logs login-server --tail 100 | grep -i "auth\|login\|reject\|failed\|banned"

# 2. Verificar conexão do login-server com MariaDB
docker compose exec login-server nc -z mariadb 3306
echo $?  # 0 = ok

# 3. Verificar se conta existe e está desbloqueada
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e \
    "SELECT userid, sex, email, state, unban_time, logincount 
     FROM ragnarok.login WHERE userid='NOME_DO_JOGADOR';"

# 4. Verificar se state != 0 (conta bloqueada)
# state=0: ativa, state=5: banida pelo admin

# 5. Verificar se unban_time está no futuro
```

**Resolução:**

| Causa | Ação |
|-------|------|
| Conta com state != 0 | `UPDATE ragnarok.login SET state=0 WHERE userid='X';` |
| Conta com unban_time no futuro | `UPDATE ragnarok.login SET unban_time=0 WHERE userid='X';` |
| Conexão DB falha | Verificar credenciais em inter_athena.conf; reiniciar login-server |
| Muitas tentativas (rate limit rAthena) | Aguardar `time_allowed` ou reiniciar login-server |

#### Cenário 4: Falha de conexão com MariaDB

**Sintomas:** Logs mostram "MySQL Error" ou "Can't connect to MySQL server"

```bash
# 1. Verificar se MariaDB está acessível da rede interna
docker compose exec login-server nc -z mariadb 3306
# Se falha: MariaDB não está na mesma rede ou está down

# 2. Verificar credenciais no config gerado
docker compose exec login-server cat /rathena/conf/generated/inter_athena.conf | grep -E "sql\.(db|login|passwd)"

# 3. Verificar logs do MariaDB
docker compose logs mariadb --tail 30

# 4. Testar conexão diretamente com as credenciais do rAthena
docker compose exec mariadb mariadb -u rathena -p${DB_PASSWORD} -e "SELECT 1;"

# 5. Verificar max_connections não atingido
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e \
    "SHOW GLOBAL STATUS LIKE 'Threads_connected';
     SHOW GLOBAL VARIABLES LIKE 'max_connections';"
```

**Resolução:**

| Causa | Ação |
|-------|------|
| MariaDB down | `docker compose restart mariadb`; aguardar healthy |
| Credenciais incorretas | Corrigir DB_USER/DB_PASS no .env; `docker compose up -d login-server` |
| max_connections atingido | Aumentar em db/conf.d/custom.cnf; `docker compose restart mariadb` |
| Rede Docker com problema | `docker compose down && docker compose up -d` |

---

### 2.2 Char Server (porta 6121)

#### Cenário 1: Não conecta ao Login Server

**Sintomas:** Logs mostram "Connection to login-server FAILED" ou "Inter-Server Authentication Failed"

```bash
# 1. Verificar se Login Server está healthy
docker compose ps login-server
# Deve estar "healthy"

# 2. Verificar conectividade de rede entre containers
docker compose exec char-server nc -z login-server 6900
# Se falha: problema de rede Docker

# 3. Verificar Inter_Server_Password em ambos os serviços
echo "=== Login Server ==="
docker compose exec login-server cat /rathena/conf/generated/inter_athena.conf | grep "passwd"
echo "=== Char Server ==="
docker compose exec char-server cat /rathena/conf/generated/inter_athena.conf | grep "passwd"
# Ambos DEVEM ter o mesmo valor

# 4. Verificar logs detalhados
docker compose logs char-server --tail 50 | grep -i "login\|connect\|auth\|reject"
```

**Resolução:**

| Causa | Ação |
|-------|------|
| Login Server não está healthy | Resolver Login Server primeiro (ver seção 2.1) |
| Inter_Server_Password diferente | Corrigir INTER_SERVER_PASSWORD no .env; `docker compose up -d` (regenera configs) |
| Rede Docker isolando containers | `docker network inspect rathena-infra_rathena-internal`; recrear se necessário |
| Login Server sobrecarregado | `docker compose restart login-server`; aguardar healthy; `docker compose restart char-server` |

#### Cenário 2: Erro ao carregar dados de personagem

**Sintomas:** Jogadores travam na tela de seleção de personagem; logs mostram erros de DB

```bash
# 1. Verificar logs do char-server
docker compose logs char-server --tail 50 | grep -i "char\|load\|error\|sql"

# 2. Verificar integridade das tabelas de personagem
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
    CHECK TABLE ragnarok.char_;
    CHECK TABLE ragnarok.inventory;
    CHECK TABLE ragnarok.cart_inventory;
    CHECK TABLE ragnarok.storage_;
    CHECK TABLE ragnarok.skill;
    CHECK TABLE ragnarok.memo;
"

# 3. Verificar se é problema com personagem específico
docker compose logs char-server | grep -i "char_id\|account_id" | tail -10

# 4. Verificar espaço em disco (tabela pode ter crescido demais)
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
    SELECT table_name, ROUND((data_length + index_length) / 1024 / 1024, 2) AS 'Size_MB'
    FROM information_schema.tables WHERE table_schema='ragnarok'
    ORDER BY (data_length + index_length) DESC LIMIT 10;
"
```

**Resolução:**

| Causa | Ação |
|-------|------|
| Tabela corrompida | `REPAIR TABLE ragnarok.char_;` (ou tabela indicada nos logs) |
| Personagem com dados inválidos | Identificar char_id; corrigir manualmente ou restaurar backup |
| Disco cheio impedindo leitura | Liberar espaço (ver MariaDB Cenário 5) |
| Conexão DB timeout | Verificar max_connections; reiniciar char-server |

#### Cenário 3: Timeout de comunicação

**Sintomas:** Char Server fica "Restarting"; logs mostram timeout de comunicação com Login Server ou MariaDB

```bash
# 1. Verificar latência entre containers
docker compose exec char-server ping -c 5 login-server
docker compose exec char-server ping -c 5 mariadb

# 2. Verificar carga da rede Docker
docker network inspect rathena-infra_rathena-internal
# Verificar se há muitos containers na mesma rede

# 3. Verificar se MariaDB está com locks longos
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e \
    "SELECT * FROM information_schema.INNODB_TRX WHERE trx_started < NOW() - INTERVAL 30 SECOND;"

# 4. Verificar uso de recursos do host
docker stats --no-stream
free -h
```

**Resolução:**

| Causa | Ação |
|-------|------|
| Rede Docker degradada | `docker compose down && docker compose up -d` (recria redes) |
| MariaDB com locks longos | KILL transação problemática; otimizar queries |
| Host com memória insuficiente | Verificar `free -h`; considerar aumentar RAM ou reduzir limits |
| Login Server reiniciando | Aguardar Login Server estabilizar; char-server reconecta automaticamente |

#### Cenário 4: Inter_Server_Password incorreta

**Sintomas:** Logs do char-server mostram "Inter-Server Authentication Failed"; server reinicia em loop

```bash
# 1. Confirmar o sintoma nos logs
docker compose logs char-server --tail 20 | grep -i "auth.*fail\|password\|rejected"

# 2. Comparar senha em TODOS os serviços (devem ser idênticas)
for svc in login-server char-server map-server; do
    echo "=== $svc ==="
    docker compose exec $svc cat /rathena/conf/generated/inter_athena.conf | grep "passwd"
done

# 3. Verificar o valor no .env
grep INTER_SERVER_PASSWORD .env

# 4. Verificar se o template está correto
cat conf/templates/inter_athena.conf.tmpl | grep passwd
```

**Resolução:**

```bash
# 1. Corrigir a senha no .env (garantir que é a mesma para todos)
nano .env
# INTER_SERVER_PASSWORD=SuaSenhaForteAqui

# 2. Recriar containers (regenera configs via entrypoint)
docker compose up -d

# 3. Verificar que todos conectaram
docker compose logs char-server --tail 10 | grep -i "connect"
docker compose logs map-server --tail 10 | grep -i "connect"
```

---

### 2.3 Map Server (porta 5121)

#### Cenário 1: Crash recorrente

**Sintomas:** Map Server reinicia continuamente; `docker compose ps` mostra "Restarting"

```bash
# 1. Verificar logs de crash (segfault, signal, abort)
docker compose logs map-server --tail 100 | grep -i "error\|crash\|signal\|segfault\|abort\|killed"

# 2. Verificar se é OOM Kill
docker compose logs map-server | grep -i "oom\|killed"
docker inspect $(docker compose ps -q map-server) | grep -A3 "OOMKilled"

# 3. Verificar se é problema de NPC script customizado
docker compose logs map-server | grep -i "npc\|script\|parse\|error" | tail -20

# 4. Verificar uso de memória antes do crash
docker stats map-server --no-stream

# 5. Verificar core dump (se habilitado)
docker compose exec map-server ls -la /tmp/core* 2>/dev/null
```

**Resolução:**

| Causa | Ação |
|-------|------|
| OOM Kill (memória insuficiente) | Aumentar `deploy.resources.limits.memory` no docker-compose.yml |
| NPC script com erro de parse | Corrigir script ou remover de npc/custom/; reiniciar |
| Bug no rAthena (segfault) | Atualizar para versão mais recente; reportar no GitHub |
| Dados corrompidos no DB | CHECK TABLE nas tabelas de mapa; restaurar backup se necessário |

**Isolamento de NPC scripts customizados:**
```bash
# Testar sem scripts custom (comentar volume no docker-compose.yml)
# Ou renomear temporariamente:
mv npc/custom npc/custom.bak
mkdir npc/custom
docker compose restart map-server
# Se parar de crashar: problema é em um NPC script custom
```

#### Cenário 2: Lag excessivo (high tick time)

**Sintomas:** Jogadores reportam lag; ações demoram para processar; mobs se movem com delay

```bash
# 1. Verificar tick time nos logs
docker compose logs map-server --tail 200 | grep -i "tick\|lag\|slow\|delay"

# 2. Verificar uso de CPU do container
docker stats map-server --no-stream
# Se CPU está próximo ao limit (ex: 200% de 200% = 2 cores), é gargalo

# 3. Verificar slow queries que podem bloquear o map-server
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e \
    "SHOW FULL PROCESSLIST;" | grep -v Sleep

# 4. Verificar spawn de mobs (excesso pode causar lag)
docker compose logs map-server | grep -ic "spawn"

# 5. Verificar se há muitas conexões simultâneas
docker compose exec map-server ss -s

# 6. Verificar métricas do host
top -bn1 | head -5
iostat -x 1 3  # I/O do disco
```

**Resolução:**

| Causa | Ação |
|-------|------|
| CPU no limite | Aumentar `cpus` no docker-compose.yml (ex: 2.0 → 3.0) |
| Slow queries bloqueando | Otimizar queries; adicionar índices; `KILL` queries longas |
| NPC scripts com OnTimer excessivos | Otimizar scripts; reduzir frequência de timers |
| Mob spawn excessivo | Reduzir taxa de spawn em scripts custom |
| I/O de disco lento | Verificar IOPS do disco; considerar SSD/NVMe |

#### Cenário 3: Desconexão em massa de jogadores

**Sintomas:** Todos ou maioria dos jogadores desconectam simultaneamente

```bash
# 1. Verificar se map-server ainda está rodando
docker compose ps map-server

# 2. Verificar logs do momento da desconexão
docker compose logs map-server --since "5m" | grep -i "disconnect\|timeout\|closed\|error"

# 3. Verificar se é ataque DDoS
sudo ss -tn state established dst :5121 | wc -l  # Conexões ativas
sudo ss -tn state established dst :5121 | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -rn | head -10
# Se um IP tem centenas de conexões: provável DDoS

# 4. Verificar rate limiting e drops
sudo iptables -L -n -v | grep -i "drop\|hashlimit"

# 5. Verificar rede do host
ping -c 5 8.8.8.8  # Conectividade externa
mtr --report google.com  # Rota de rede

# 6. Verificar se o char-server caiu (causa desconexão no map)
docker compose ps char-server
```

**Resolução:**

| Causa | Ação |
|-------|------|
| DDoS em andamento | Ativar proteção L4 no provedor; bloquear IPs agressivos |
| Char-server caiu | Reiniciar char-server (map-server reconecta automaticamente) |
| Rede do host instável | Contactar provedor de hosting; verificar rotas |
| Map-server crashou | Verificar logs; reiniciar: `docker compose restart map-server` |
| Problema de rede Docker | `docker compose down && docker compose up -d` |

#### Cenário 4: Consumo excessivo de memória

**Sintomas:** Map Server usando >90% do memory limit; OOM Kill iminente ou já ocorrendo

```bash
# 1. Verificar uso atual vs limite
docker stats map-server --no-stream
# MEM USAGE / LIMIT mostra a relação

# 2. Verificar se já houve OOM Kill
docker inspect $(docker compose ps -q map-server) --format='{{.State.OOMKilled}}'

# 3. Verificar limites configurados
docker inspect $(docker compose ps -q map-server) | grep -A5 "Memory"

# 4. Verificar crescimento de memória ao longo do tempo (possível leak)
# Executar a cada 5 minutos e comparar:
docker stats map-server --no-stream --format "{{.MemUsage}}"

# 5. Verificar número de jogadores online (proporcional ao uso de memória)
docker compose logs map-server | grep -i "users\|online\|connected" | tail -5
```

**Resolução:**

| Causa | Ação |
|-------|------|
| Memory limit insuficiente | Aumentar `deploy.resources.limits.memory` (ex: 2048M → 3072M) |
| Memory leak em NPC scripts | Identificar e corrigir scripts com arrays/variáveis não liberadas |
| Muitos jogadores simultâneos | Aumentar memória proporcionalmente; ~50MB por 100 jogadores |
| Bug de memory leak no rAthena | Agendar restart periódico como workaround; reportar upstream |

**Workaround para memory leak (restart agendado):**
```bash
# Adicionar ao crontab do host (reinicia diariamente às 06:00 com aviso)
# 0 6 * * * docker compose restart map-server
```

---

### 2.4 MariaDB

#### Cenário 1: Container não inicia

**Sintomas:** `docker compose ps mariadb` mostra "Exit" ou "Restarting"

```bash
# 1. Verificar logs detalhados
docker compose logs mariadb --tail 100

# 2. Verificar espaço em disco
df -h /var/lib/docker/volumes/
df -h

# 3. Verificar se innodb_buffer_pool_size é maior que memória disponível
grep innodb_buffer_pool_size db/conf.d/custom.cnf
docker compose logs mariadb | grep -i "buffer pool\|cannot allocate\|memory"

# 4. Verificar permissões do volume
docker run --rm -v rathena-infra_rathena-db-data:/data alpine ls -la /data/

# 5. Verificar se é problema de primeira inicialização
docker compose logs mariadb | grep -i "init\|bootstrap\|error"
```

**Resolução:**

| Causa | Ação |
|-------|------|
| Disco cheio | Liberar espaço: `docker system prune -f`; purgar logs antigos |
| buffer_pool_size > RAM disponível | Reduzir em db/conf.d/custom.cnf (ou ajustar container memory limit) |
| Volume com permissões incorretas | `docker volume rm rathena-infra_rathena-db-data` (⚠️ PERDE DADOS - restaurar backup!) |
| Script de inicialização com erro | Verificar sql/00-setup-users.sql; corrigir sintaxe SQL |
| my.cnf com configuração inválida | Validar db/conf.d/custom.cnf; comentar linha suspeita |

#### Cenário 2: Corrupção de tabela InnoDB

**Sintomas:** Erros "Table is marked as crashed", "InnoDB: corruption in tablespace", queries falham

```bash
# 1. Verificar quais tabelas estão corrompidas
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
    CHECK TABLE ragnarok.login;
    CHECK TABLE ragnarok.char_;
    CHECK TABLE ragnarok.inventory;
    CHECK TABLE ragnarok.cart_inventory;
    CHECK TABLE ragnarok.storage_;
    CHECK TABLE ragnarok.guild;
    CHECK TABLE ragnarok.party;
"

# 2. Verificar status do InnoDB
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW ENGINE INNODB STATUS\G" | grep -A10 "LATEST FOREIGN KEY ERROR\|LATEST DETECTED DEADLOCK\|SEMAPHORES"

# 3. Verificar logs do MariaDB para detalhes
docker compose logs mariadb | grep -i "corrupt\|crash\|error\|recovery"
```

**Resolução — Corrupção leve (tabela específica):**
```bash
# Tentar reparo
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e \
    "REPAIR TABLE ragnarok.<tabela_corrompida>;"

# Se REPAIR não funcionar, tentar OPTIMIZE
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e \
    "OPTIMIZE TABLE ragnarok.<tabela_corrompida>;"
```

**Resolução — Corrupção grave (InnoDB não inicia):**
```bash
# 1. Parar MariaDB
docker compose stop mariadb

# 2. Adicionar recovery mode ao custom.cnf (temporário!)
echo "innodb_force_recovery = 1" >> db/conf.d/custom.cnf

# 3. Iniciar em recovery mode
docker compose start mariadb

# 4. Exportar todos os dados
docker compose exec mariadb mariadb-dump -u root -p${MYSQL_ROOT_PASSWORD} \
    --all-databases --single-transaction > /tmp/emergency_dump.sql

# 5. Parar MariaDB e remover recovery mode
docker compose stop mariadb
sed -i '/innodb_force_recovery/d' db/conf.d/custom.cnf

# 6. Remover volume corrompido e restaurar
docker volume rm rathena-infra_rathena-db-data
docker compose up -d mariadb
# Aguardar inicialização limpa, depois importar dump ou restaurar backup

# Se recovery mode 1 não funcionar, incrementar (2, 3... até 6 máximo)
# ATENÇÃO: recovery >= 4 pode causar perda de dados
```

**Se impossível recuperar: restaurar do último backup:**
```bash
sudo bash scripts/restore.sh /backups/rathena_db_<ultimo_backup>.sql.gz
```

#### Cenário 3: Performance degradada (slow queries)

**Sintomas:** Jogadores com lag em ações que envolvem DB (salvar personagem, acessar storage, guild)

```bash
# 1. Verificar slow query log
docker compose exec mariadb tail -100 /var/lib/mysql/slow-query.log

# 2. Verificar queries em execução
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e \
    "SELECT ID, USER, HOST, DB, COMMAND, TIME, STATE, INFO 
     FROM information_schema.PROCESSLIST 
     WHERE COMMAND != 'Sleep' AND TIME > 2
     ORDER BY TIME DESC;"

# 3. Verificar buffer pool hit rate (deve ser >99%)
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
    SELECT 
        (1 - (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='Innodb_buffer_pool_reads') /
             (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='Innodb_buffer_pool_read_requests')
        ) * 100 AS buffer_pool_hit_rate_percent;
"

# 4. Verificar se max_connections está saturado
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
    SHOW GLOBAL STATUS LIKE 'Threads_connected';
    SHOW GLOBAL STATUS LIKE 'Max_used_connections';
    SHOW GLOBAL VARIABLES LIKE 'max_connections';
"

# 5. Verificar InnoDB status
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW ENGINE INNODB STATUS\G" | head -80
```

**Resolução:**

| Causa | Ação |
|-------|------|
| Buffer pool hit rate < 99% | Aumentar `innodb_buffer_pool_size` em custom.cnf; reiniciar MariaDB |
| Queries sem índice | `EXPLAIN` na query lenta; adicionar índice apropriado |
| max_connections atingido | Aumentar em custom.cnf ou via .env; reiniciar MariaDB |
| Lock contention | Verificar cenário de locks (ver Cenário 4) |
| Disco lento (I/O) | Verificar `iostat`; migrar para SSD/NVMe |

#### Cenário 4: Locks excessivos

**Sintomas:** Queries travam; jogadores com ações pendentes; "Lock wait timeout exceeded"

```bash
# 1. Verificar locks ativos
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
    SELECT * FROM information_schema.INNODB_LOCKS;
"

# 2. Verificar transações abertas há muito tempo
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
    SELECT trx_id, trx_state, trx_started, trx_mysql_thread_id, trx_query,
           TIMESTAMPDIFF(SECOND, trx_started, NOW()) AS duration_seconds
    FROM information_schema.INNODB_TRX 
    WHERE trx_started < NOW() - INTERVAL 30 SECOND
    ORDER BY trx_started;
"

# 3. Verificar lock waits
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
    SELECT * FROM information_schema.INNODB_LOCK_WAITS;
"

# 4. Identificar a query que está bloqueando
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
    SELECT r.trx_id AS waiting_trx_id, r.trx_query AS waiting_query,
           b.trx_id AS blocking_trx_id, b.trx_query AS blocking_query
    FROM information_schema.INNODB_LOCK_WAITS w
    JOIN information_schema.INNODB_TRX b ON b.trx_id = w.blocking_trx_id
    JOIN information_schema.INNODB_TRX r ON r.trx_id = w.requesting_trx_id;
"
```

**Resolução:**
```bash
# Matar a transação que está causando o lock
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "KILL <thread_id>;"

# Se é o backup causando locks (improvável com --single-transaction, mas possível):
# Aguardar backup finalizar ou ajustar horário do cron

# Se locks são recorrentes: verificar se há deadlocks
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW ENGINE INNODB STATUS\G" | grep -A20 "LATEST DETECTED DEADLOCK"
```

#### Cenário 5: Disco cheio

**Sintomas:** Writes falham; "No space left on device"; logs param de ser escritos

```bash
# 1. Verificar espaço em disco
df -h
df -h /var/lib/docker/volumes/

# 2. Identificar o que está consumindo espaço
du -sh /var/lib/docker/volumes/rathena-infra_rathena-db-data/_data/
docker system df -v

# 3. Verificar tamanho dos bancos
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
    SELECT table_schema AS 'Database',
           ROUND(SUM(data_length + index_length) / 1024 / 1024, 2) AS 'Size_MB'
    FROM information_schema.tables
    GROUP BY table_schema
    ORDER BY SUM(data_length + index_length) DESC;
"

# 4. Verificar binary logs (podem ser grandes)
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW BINARY LOGS;"

# 5. Verificar logs Docker
du -sh /var/lib/docker/containers/*/
```

**Resolução — Ações imediatas:**
```bash
# 1. Purgar binary logs antigos (manter últimos 3 dias)
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e \
    "PURGE BINARY LOGS BEFORE NOW() - INTERVAL 3 DAY;"

# 2. Limpar logs Docker antigos
docker system prune -f --volumes  # ⚠️ Remove volumes não usados!
# Ou mais seguro, apenas containers parados e imagens dangling:
docker system prune -f

# 3. Truncar logs aplicacionais do rAthena
sudo truncate -s 0 /opt/rathena/logs/login/login-server.log
sudo truncate -s 0 /opt/rathena/logs/char/char-server.log
sudo truncate -s 0 /opt/rathena/logs/map/map-server.log

# 4. Forçar rotação de backups
find /backups/ -name "*.sql.gz" -mtime +7 -delete

# 5. Se nada funcionar: expandir disco do servidor (no provedor de hosting)
```

**Prevenção:**
```bash
# Verificar que logrotate está ativo
sudo logrotate --debug /etc/logrotate.d/rathena

# Verificar que rotação de backups está funcionando
ls -lh /backups/ | wc -l  # Não deve exceder 30 arquivos

# Monitorar via Zabbix (alerta em <10% de disco livre)
```

---

## Seção 3: Operações de Rotina

### 3.1 Restauração de Backup

**Quando usar:** Após corrupção de dados, atualização falha, ou necessidade de reverter estado do banco.

**Pré-requisitos:**
- Acesso SSH ao servidor
- Arquivo de backup disponível em `/backups/` ou caminho conhecido
- Permissão sudo

**Procedimento:**

```bash
# 1. Listar backups disponíveis (mais recente primeiro)
ls -lht /backups/rathena_db_*.sql.gz | head -10

# 2. Verificar integridade do arquivo de backup
gunzip -t /backups/rathena_db_YYYY-MM-DD_HHmmss.sql.gz
echo $?  # 0 = arquivo íntegro

# 3. Executar restauração via script
sudo bash scripts/restore.sh /backups/rathena_db_YYYY-MM-DD_HHmmss.sql.gz

# --- O script restore.sh executa automaticamente: ---
# a) Para serviços rAthena (login, char, map)
# b) Valida arquivo de backup (existência + integridade gzip)
# c) Restaura banco via gunzip | mariadb
# d) Verifica integridade (CHECK TABLE nas tabelas principais)
# e) Reinicia serviços na ordem correta (login → char → map)
```

**Verificação pós-restore:**
```bash
# 4. Verificar que todos os serviços estão healthy
docker compose ps
# Todos devem mostrar "healthy"

# 5. Verificar integridade dos dados
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
    SELECT COUNT(*) AS total_accounts FROM ragnarok.login;
    SELECT COUNT(*) AS total_chars FROM ragnarok.char_;
"

# 6. Testar login de um jogador
# Conectar com o cliente RO e verificar se personagens estão corretos
```

**Estimativa de tempo:**
- Banco até 5GB: < 15 minutos
- Banco > 5GB: ~3 minutos por GB adicional
- O script registra progresso em log para acompanhamento

**Objetivos de recuperação (SLA):**
- **RTO** (Recovery Time Objective): 30 minutos
- **RPO** (Recovery Point Objective): 24 horas (backup completo) ou minutos (com binary logs)

---

### 3.2 Atualização do rAthena

**Quando usar:** Quando há CVEs publicadas, novos features necessários, ou bugfixes importantes.

**Procedimento completo:**

```bash
# ============================================================
# FASE 1: Verificação de CVEs e Planejamento
# ============================================================

# 1. Verificar advisories de segurança do rAthena
# Acessar: https://github.com/rathena/rathena/security/advisories
# Verificar: https://github.com/rathena/rathena/releases (changelog)

# 2. Verificar o commit/branch atual
grep RATHENA_BRANCH .env 2>/dev/null || grep RATHENA_BRANCH Dockerfile

# 3. Ler changelog entre versão atual e nova
# Identificar breaking changes que afetam a infraestrutura

# ============================================================
# FASE 2: Backup Pré-Atualização
# ============================================================

# 4. Executar backup completo ANTES de qualquer mudança
docker compose exec backup /scripts/backup.sh
# Verificar que backup foi criado com sucesso:
ls -lh /backups/rathena_db_$(date +%Y-%m-%d)*.sql.gz

# 5. Backup adicional das configurações
tar -czf /backups/pre-update-config-$(date +%Y%m%d).tar.gz \
    .env conf/ npc/custom/ db/conf.d/ docker-compose.yml

# ============================================================
# FASE 3: Rebuild das Imagens
# ============================================================

# 6. Atualizar referência do código
# Opção A: Atualizar branch (pega último commit do master)
# Opção B: Fixar em commit específico (recomendado para produção)
nano .env
# RATHENA_BRANCH=master  ou  RATHENA_BRANCH=<commit_sha>

# 7. Rebuild das imagens sem cache
docker compose build --no-cache login-server char-server map-server

# 8. Verificar que o build foi bem-sucedido
docker compose images | grep rathena

# ============================================================
# FASE 4: Deploy com Validação
# ============================================================

# 9. Deploy dos novos containers
docker compose up -d login-server char-server map-server

# 10. Aguardar healthchecks passarem (até 120s de start_period)
echo "Aguardando healthchecks..."
sleep 30
docker compose ps
# Repetir até todos estarem "healthy"

# 11. Verificar logs por erros
docker compose logs login-server --tail 20 | grep -i error
docker compose logs char-server --tail 20 | grep -i error
docker compose logs map-server --tail 20 | grep -i error

# 12. Testar funcionalidade (checklist)
# [ ] Login de jogador funciona
# [ ] Criação de personagem funciona
# [ ] Entrar no jogo funciona
# [ ] NPCs respondem
# [ ] Storage funciona

# ============================================================
# FASE 5: Rollback (SE NECESSÁRIO)
# ============================================================

# Se a atualização causou problemas:
# Ver seção 3.3 "Rollback de Deploy"
```

**Notas importantes:**
- Sempre atualizar em horário de baixo uso (madrugada do servidor)
- Anunciar manutenção aos jogadores com antecedência
- Manter o backup pré-update por pelo menos 7 dias
- Se múltiplas CVEs: priorizar por severidade (Critical > High > Medium)

---

### 3.3 Rollback de Deploy

**Quando usar:** Após atualização ou deploy que causou instabilidade, crashes, ou bugs críticos.

#### Rollback via imagens taggeadas (CI/CD com GHCR)

```bash
# 1. Identificar a versão anterior
docker compose images | grep rathena
# Ou consultar GitHub Actions para tag do último deploy estável

# 2. Atualizar tag no .env para SHA do commit anterior
nano .env
# IMAGE_TAG=sha-abc1234  →  IMAGE_TAG=sha-xyz9876 (versão anterior)

# 3. Pull das imagens anteriores
docker compose pull login-server char-server map-server

# 4. Recreate containers com imagens anteriores
docker compose up -d login-server char-server map-server

# 5. Verificar healthchecks
docker compose ps
```

#### Rollback via build local (sem GHCR)

```bash
# 1. Identificar o commit anterior funcional
git log --oneline -10

# 2. Checkout do commit anterior
git checkout <commit_anterior_estável>

# 3. Rebuild das imagens
docker compose build login-server char-server map-server

# 4. Deploy
docker compose up -d login-server char-server map-server

# 5. Verificar
docker compose ps
docker compose logs --tail 10 login-server char-server map-server
```

#### Rollback do banco de dados (se necessário)

```bash
# Se a atualização alterou schema do banco e precisa reverter:
sudo bash scripts/restore.sh /backups/pre-update-config-YYYYMMDD.sql.gz

# ⚠️ ATENÇÃO: Restaurar backup do banco pode causar perda de dados
# criados entre o backup e o momento do restore (progresso de jogadores)
```

#### Via GitHub Actions Workflow (automatizado)

```bash
# Usar o workflow de rollback via GitHub UI ou CLI:
gh workflow run rollback.yml
# O workflow automaticamente:
# 1. Identifica tag do commit anterior
# 2. Faz pull das imagens anteriores
# 3. Recria containers
```

---

## Seção 4: Comandos de Diagnóstico por Categoria

### 4.1 Logs de Containers

```bash
# Ver logs de todos os serviços (últimas 50 linhas)
docker compose logs --tail 50

# Logs de serviço específico
docker compose logs login-server --tail 100
docker compose logs char-server --tail 100
docker compose logs map-server --tail 100
docker compose logs mariadb --tail 100

# Seguir logs em tempo real
docker compose logs -f map-server
docker compose logs -f --tail 0 login-server char-server  # Múltiplos serviços

# Filtrar por padrão (erros e warnings)
docker compose logs map-server 2>&1 | grep -i "error\|warning\|fatal" | tail -30

# Logs com timestamp explícito
docker compose logs --timestamps login-server --since "1h" | tail -30

# Logs por intervalo de tempo
docker compose logs --since "2025-01-15T10:00:00" --until "2025-01-15T11:00:00" map-server

# Logs aplicacionais do rAthena no host
tail -100 /opt/rathena/logs/login/login-server.log
tail -100 /opt/rathena/logs/char/char-server.log
tail -100 /opt/rathena/logs/map/map-server.log

# Buscar em logs aplicacionais
grep -i "error" /opt/rathena/logs/map/map-server.log | tail -20
```

### 4.2 Métricas de Sistema

```bash
# Uso de recursos por container (CPU, memória, rede, I/O)
docker stats --no-stream
docker stats --no-stream --format "table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}"

# Uso de disco do Docker
docker system df
docker system df -v  # Detalhado

# Uso de disco do host
df -h
du -sh /var/lib/docker/volumes/*/

# Memória do host
free -h
cat /proc/meminfo | head -5

# CPU do host
top -bn1 | head -20
mpstat -P ALL 1 3  # CPU por core

# I/O de disco
iostat -x 1 5

# Rede do host
ss -tlnp   # Portas escutando
ss -s      # Resumo de conexões
iftop -n   # Tráfego de rede em tempo real (se instalado)

# Carga do sistema
uptime
cat /proc/loadavg
```

### 4.3 Conexões no MariaDB

```bash
# Lista de processos ativos
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW PROCESSLIST;"

# Processos com detalhes completos (query truncada vs full)
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "SHOW FULL PROCESSLIST;"

# Conexões agrupadas por usuário
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
    SELECT user, host, db, command, COUNT(*) AS count
    FROM information_schema.processlist
    GROUP BY user, host, db, command
    ORDER BY count DESC;
"

# Threads conectadas vs máximo
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
    SELECT 
        (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='Threads_connected') AS connected,
        (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS WHERE VARIABLE_NAME='Max_used_connections') AS max_used,
        (SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_VARIABLES WHERE VARIABLE_NAME='max_connections') AS max_allowed;
"

# Conexões abortadas (indicador de problemas de rede ou auth)
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
    SHOW GLOBAL STATUS LIKE 'Aborted_%';
"
```

### 4.4 Queries Lentas

```bash
# Verificar se slow query log está habilitado
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
    SHOW GLOBAL VARIABLES LIKE 'slow_query_log%';
    SHOW GLOBAL VARIABLES LIKE 'long_query_time';
"

# Últimas slow queries registradas
docker compose exec mariadb tail -50 /var/lib/mysql/slow-query.log

# Queries em execução agora que estão lentas (>5 segundos)
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
    SELECT ID, USER, HOST, DB, TIME, STATE, LEFT(INFO, 100) AS query
    FROM information_schema.PROCESSLIST
    WHERE COMMAND != 'Sleep' AND TIME > 5
    ORDER BY TIME DESC;
"

# Estatísticas gerais de queries
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} -e "
    SHOW GLOBAL STATUS LIKE 'Slow_queries';
    SHOW GLOBAL STATUS LIKE 'Questions';
    SHOW GLOBAL STATUS LIKE 'Com_select';
    SHOW GLOBAL STATUS LIKE 'Com_insert';
    SHOW GLOBAL STATUS LIKE 'Com_update';
    SHOW GLOBAL STATUS LIKE 'Com_delete';
"

# Analisar query específica
docker compose exec mariadb mariadb -u root -p${MYSQL_ROOT_PASSWORD} ragnarok -e "
    EXPLAIN SELECT * FROM char_ WHERE account_id = 2000000;
"
```

### 4.5 Estado dos Healthchecks

```bash
# Status resumido de todos os containers
docker compose ps

# Status detalhado com healthcheck de um container específico
docker inspect --format='{{json .State.Health}}' $(docker compose ps -q login-server) | jq .
docker inspect --format='{{json .State.Health}}' $(docker compose ps -q char-server) | jq .
docker inspect --format='{{json .State.Health}}' $(docker compose ps -q map-server) | jq .
docker inspect --format='{{json .State.Health}}' $(docker compose ps -q mariadb) | jq .

# Testar healthchecks manualmente
docker compose exec login-server nc -z localhost 6900 && echo "OK" || echo "FAIL"
docker compose exec char-server nc -z localhost 6121 && echo "OK" || echo "FAIL"
docker compose exec map-server nc -z localhost 5121 && echo "OK" || echo "FAIL"
docker compose exec mariadb healthcheck.sh --connect --innodb_initialized && echo "OK" || echo "FAIL"

# Verificar logs do autoheal (restart automáticos)
docker compose logs autoheal --tail 30

# Verificar eventos de restart
docker events --since "1h" --filter "event=restart" --filter "event=die" --format "{{.Time}} {{.Actor.Attributes.name}} {{.Action}}"

# Histórico de healthchecks falhos
docker inspect --format='{{range .State.Health.Log}}{{.Start}} - {{.ExitCode}} - {{.Output}}{{"\n"}}{{end}}' $(docker compose ps -q login-server)
```

### 4.6 Rede e Firewall

```bash
# Status do UFW
sudo ufw status verbose
sudo ufw status numbered  # Para remoção de regras específicas

# Regras iptables (rate limiting do rAthena)
sudo iptables -L INPUT -n -v | grep -E "hashlimit|connlimit|6900|6121|5121"

# IPs banidos pelo fail2ban
sudo fail2ban-client status sshd

# Desbanir um IP no fail2ban
sudo fail2ban-client set sshd unbanip <IP_ADDRESS>

# Conexões por IP (detectar DDoS ou abuso)
sudo ss -tn state established | awk '{print $5}' | cut -d: -f1 | sort | uniq -c | sort -rn | head -20

# Conexões por porta
sudo ss -tn state established | awk '{print $4}' | rev | cut -d: -f1 | rev | sort | uniq -c | sort -rn

# Verificar redes Docker
docker network ls
docker network inspect rathena-infra_rathena-internal
docker network inspect rathena-infra_rathena-external

# Testar conectividade entre containers
docker compose exec login-server ping -c 3 mariadb
docker compose exec char-server ping -c 3 login-server
docker compose exec map-server ping -c 3 char-server
```

### 4.7 Backup e Storage

```bash
# Listar backups disponíveis
ls -lht /backups/rathena_db_*.sql.gz | head -10

# Verificar último backup (tamanho e data)
ls -lh /backups/rathena_db_*.sql.gz | tail -1

# Verificar integridade de um backup
gunzip -t /backups/rathena_db_<arquivo>.sql.gz && echo "OK" || echo "CORROMPIDO"

# Verificar log do último backup
docker compose logs backup --tail 20

# Espaço usado por backups
du -sh /backups/

# Executar backup manual
docker compose exec backup /scripts/backup.sh

# Verificar crontab do backup
docker compose exec backup crontab -l
```

---

## Apêndice: Contatos e Escalação

| Nível | Quem | Quando |
|-------|------|--------|
| L1 | Administrador de plantão | Alerta Zabbix disparado |
| L2 | Administrador sênior | Incidente não resolvido em 30 min |
| L3 | Desenvolvedor rAthena | Bug no código do emulador |
| Provedor | Hosting/Cloud provider | Problema de rede/hardware/DDoS L4 |

**Canais de notificação configurados:** Discord/Telegram/Slack (via webhook Zabbix)
