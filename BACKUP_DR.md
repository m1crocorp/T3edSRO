# Backup e Recuperação de Desastres — rAthena Server Infrastructure

## Visão Geral

O sistema de backup garante recuperação de dados em caso de falha catastrófica, com backup automatizado diário, retenção de 30 dias e capacidade de recuperação point-in-time via binary logs.

## Objetivos de Recuperação

| Cenário | RPO (Perda máxima) | RTO (Tempo de recuperação) | Método |
|---------|--------------------|-----------------------------|--------|
| Backup completo | 24 horas | 30 minutos | Restore do dump SQL |
| Com Binary Logs | Minutos | 45 minutos | Dump + binlog replay |
| Configurações | 24 horas | 5 minutos | Restore do tar.gz |

## Backup Automático

### Agendamento

- **Frequência**: Diário
- **Horário**: 04:00 UTC (horário de menor atividade)
- **Container**: Backup Service (imagem `mariadb:11.4` para ter `mariadb-dump`)
- **Volume**: `rathena-backups` (separado do volume de dados do MariaDB)

### O que é backupado

| Item | Formato | Padrão de nome |
|------|---------|----------------|
| Banco de dados completo | SQL comprimido (gzip) | `rathena_db_YYYY-MM-DD_HHmmss.sql.gz` |
| Configurações + NPCs | tar.gz | `rathena_config_YYYY-MM-DD.tar.gz` |

### Comando de Backup

```bash
mariadb-dump \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    --databases ragnarok ragnarok_log \
    -h mariadb \
    -u rathena_backup \
    -p"${BACKUP_DB_PASSWORD}" \
    | gzip > /backups/rathena_db_$(date +%Y-%m-%d_%H%M%S).sql.gz
```

Opções:
- `--single-transaction`: Backup consistente sem lock (InnoDB)
- `--routines`: Inclui stored procedures e functions
- `--triggers`: Inclui triggers
- `--events`: Inclui eventos agendados

### Backup de Configurações

```bash
tar czf /backups/rathena_config_$(date +%Y-%m-%d).tar.gz \
    /rathena/conf/ \
    /rathena/npc/custom/
```

### Retenção

- Backups são retidos por **30 dias**
- Rotação diária: backups mais antigos que 30 dias são removidos automaticamente
- Binary logs: retidos por **7 dias** (configuração `expire_logs_days=7`)

### Logging

Cada operação de backup registra:
- Timestamp de início e fim
- Tamanho do arquivo gerado
- Duração da operação
- Status: sucesso ou falha (com código de saída)

### Notificação de Falha

Se o backup falha, uma notificação é enviada via webhook com:
- Timestamp da falha
- Código de saída do processo
- Últimas 20 linhas do log de erro
- Nome do arquivo que deveria ser gerado

## Binary Logs e Recuperação Point-in-Time (PITR)

### O que são Binary Logs

Binary logs (binlogs) são registros sequenciais de todas as alterações de dados realizadas no MariaDB. Cada operação de INSERT, UPDATE, DELETE e DDL é gravada em arquivos binários nomeados sequencialmente (`mysql-bin.000001`, `mysql-bin.000002`, etc.).

Os binary logs permitem:
- **Recuperação point-in-time (PITR)**: restaurar o banco a qualquer momento entre o último backup completo e o ponto de falha
- **Redução do RPO**: de 24 horas (backup diário apenas) para **minutos** (backup + replay de binlogs)
- **Auditoria**: rastrear quais alterações foram feitas e quando

### Configuração

> ✅ **Confirmado**: Binary logging está habilitado em [`db/conf.d/custom.cnf`](db/conf.d/custom.cnf) com `log-bin=mysql-bin` e `expire_logs_days=7`. Esta configuração é montada automaticamente no container MariaDB via volume `./db/conf.d:/etc/mysql/conf.d:ro` no `docker-compose.yml`.

```ini
# db/conf.d/custom.cnf
[mysqld]
log-bin = mysql-bin
expire_logs_days = 7
```

| Parâmetro | Valor | Descrição |
|-----------|-------|-----------|
| `log-bin` | `mysql-bin` | Prefixo dos arquivos de binary log — gera arquivos sequenciais em `/var/lib/mysql/` |
| `expire_logs_days` | `7` | Dias de retenção dos binlogs (rotação automática pelo MariaDB) |

### RPO com Binary Logs

| Método de recuperação | RPO (Perda máxima de dados) |
|-----------------------|-----------------------------|
| Apenas backup diário | Até 24 horas |
| Backup + binary logs | Minutos (desde o último commit gravado nos binlogs) |

### Pré-requisitos para PITR

Para que a recuperação point-in-time funcione:

1. **Binary logs não podem estar expirados**: os binlogs entre o backup e o ponto de recuperação devem existir (janela máxima de 7 dias)
2. **Backup deve incluir posição do binlog**: o dump precisa registrar a posição exata no binary log no momento do backup (garantido pela opção `--master-data` ou pelo header do dump `--single-transaction`)
3. **Binlogs devem estar acessíveis**: os arquivos residem em `/var/lib/mysql/` dentro do volume do MariaDB
4. **Sequência de binlogs deve estar completa**: todos os arquivos entre a posição do backup e o ponto desejado devem estar presentes

### Procedimento de Recuperação Point-in-Time

**RTO estimado: ~45 minutos** (para PITR completo incluindo restore do dump + replay de binlogs)

#### Passo 1: Restaurar o último backup completo (dump diário)

```bash
# Parar serviços rAthena antes da restauração
docker compose stop login-server char-server map-server

# Restaurar o dump completo
gunzip < /backups/rathena_db_2026-06-14_040000.sql.gz | \
    docker compose exec -T mariadb mariadb -u root -p"${MARIADB_ROOT_PASSWORD}"
```

#### Passo 2: Identificar a posição do binary log no momento do backup

O `mariadb-dump` com `--single-transaction` registra a posição do binlog no header do dump. Para encontrá-la:

```bash
# Extrair posição do binlog do arquivo de backup
gunzip -c /backups/rathena_db_2026-06-14_040000.sql.gz | head -30 | grep "CHANGE MASTER"

# Saída esperada:
# -- CHANGE MASTER TO MASTER_LOG_FILE='mysql-bin.000042', MASTER_LOG_POS=12345;
```

Anotar:
- **Arquivo binlog**: `mysql-bin.000042`
- **Posição**: `12345`

#### Passo 3: Aplicar binary logs do ponto de backup até o momento desejado

```bash
# Listar binlogs disponíveis no container
docker compose exec mariadb ls -la /var/lib/mysql/mysql-bin.*

# Aplicar binlogs desde a posição do backup até o datetime desejado
docker compose exec mariadb mariadb-binlog \
    --start-position=12345 \
    /var/lib/mysql/mysql-bin.000042 \
    /var/lib/mysql/mysql-bin.000043 \
    --stop-datetime="2026-06-14 15:30:00" \
    | docker compose exec -T mariadb mariadb -u root -p"${MARIADB_ROOT_PASSWORD}"
```

> **Nota**: Inclua todos os arquivos binlog sequenciais entre a posição do backup e o ponto de recuperação. Se o backup foi feito no arquivo `000042` e o ponto desejado está no `000045`, inclua: `000042 000043 000044 000045`.

#### Passo 4: Verificar integridade dos dados

```bash
# Verificar tabelas principais
docker compose exec mariadb mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -e "
    CHECK TABLE ragnarok.login;
    CHECK TABLE ragnarok.char_;
    CHECK TABLE ragnarok.inventory;
    CHECK TABLE ragnarok.cart_inventory;
    CHECK TABLE ragnarok.storage;
    CHECK TABLE ragnarok.guild;
"

# Verificar contagens (comparar com expectativa)
docker compose exec mariadb mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -e "
    SELECT 'login' AS tbl, COUNT(*) AS rows FROM ragnarok.login
    UNION SELECT 'char_', COUNT(*) FROM ragnarok.char_
    UNION SELECT 'guild', COUNT(*) FROM ragnarok.guild;
"
```

#### Passo 5: Reiniciar serviços

```bash
# Reiniciar na ordem correta
docker compose up -d login-server
# Aguardar healthy
docker compose up -d char-server
docker compose up -d map-server

# Verificar que todos os serviços estão healthy
docker compose ps
```

### Objetivos de Recuperação — PITR vs Backup Completo

| Métrica | Backup Completo | Backup + PITR (Binary Logs) |
|---------|-----------------|------------------------------|
| **RPO** (Recovery Point Objective) | 24 horas (dados desde o último dump são perdidos) | Minutos (perda limitada ao último commit não gravado no binlog) |
| **RTO** (Recovery Time Objective) | ~30 minutos (restore direto do dump gzip) | ~45 minutos (restore do dump + replay dos binlogs relevantes) |
| **Complexidade** | Baixa — um único comando | Média — requer identificar posição no binlog e replay sequencial |
| **Janela de cobertura** | Última execução do backup (04:00 UTC) | Até 7 dias de binlogs (limitado por `expire_logs_days`) |

> **Nota sobre RTO**: O tempo de 45 minutos para PITR inclui: parar serviços (~2min), restore do dump completo (~15-25min para banco típico até 5GB), identificar posição e aplicar binlogs (~10-15min), verificar integridade e reiniciar (~5min).

### Cenários de uso do PITR

| Cenário | Ação |
|---------|------|
| Exclusão acidental de personagens | PITR até 1 minuto antes da exclusão |
| Exploit/dupe detectado às 14:00 | PITR até 13:59 (antes do exploit) |
| Corrupção após atualização de NPC | PITR até antes da atualização |
| Falha de hardware às 18:00 | PITR até o último commit nos binlogs |

### Comandos úteis para diagnóstico de binlogs

```bash
# Ver status atual do binary log
docker compose exec mariadb mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -e "SHOW MASTER STATUS;"

# Listar todos os binary logs e tamanhos
docker compose exec mariadb mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -e "SHOW BINARY LOGS;"

# Ver eventos em um binlog específico (últimos 20)
docker compose exec mariadb mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -e "SHOW BINLOG EVENTS IN 'mysql-bin.000042' LIMIT 20;"

# Decodificar binlog para leitura humana (debug)
docker compose exec mariadb mariadb-binlog --base64-output=DECODE-ROWS -v /var/lib/mysql/mysql-bin.000042 | tail -50
```

## Procedimento de Restauração

### Usando o script restore.sh

```bash
# Uso básico
sudo bash scripts/restore.sh /path/to/rathena_db_2026-06-14_040000.sql.gz
```

### O que o script faz

1. **Valida** o arquivo de backup (existência, integridade gzip)
2. **Para** os serviços rAthena (login, char, map)
3. **Restaura** o banco via `gunzip | mariadb`
4. **Verifica** integridade (CHECK TABLE nas tabelas principais)
5. **Reinicia** os serviços na ordem correta (MariaDB → Login → Char → Map)
6. **Registra** progresso em log

### Performance de Restauração

| Tamanho do banco | Tempo estimado |
|------------------|----------------|
| Até 1 GB | ~3 minutos |
| Até 5 GB | ~15 minutos |
| 5-10 GB | ~15-30 minutos (3 min/GB adicional) |
| > 10 GB | Proporcional, com progresso logado |

## Backup Manual

Para executar um backup fora do horário agendado:

```bash
# Via docker compose exec
docker compose exec backup /scripts/backup.sh

# Verificar resultado
docker compose logs backup --tail 10
```

## Verificação de Backups

### Testar integridade do arquivo

```bash
# Verificar se o gzip é válido
gunzip -t /path/to/rathena_db_2026-06-14_040000.sql.gz

# Verificar tamanho (deve ter > 0 bytes)
ls -lh /path/to/rathena_db_*.sql.gz
```

### Restore de teste (recomendado mensalmente)

```bash
# Em um ambiente de teste/staging
gunzip < backup.sql.gz | mariadb -u root -p ragnarok_test

# Verificar dados
mariadb -u root -p -e "SELECT COUNT(*) FROM ragnarok_test.login;"
mariadb -u root -p -e "SELECT COUNT(*) FROM ragnarok_test.char_;"
```

## Recuperação de Desastres — Cenários

### Cenário 1: Container MariaDB corrompido

1. Parar todos os serviços: `docker compose down`
2. Remover volume corrompido: `docker volume rm rathena-infra_rathena-db-data`
3. Recriar: `docker compose up -d mariadb` (aguardar healthy)
4. Restaurar: `bash scripts/restore.sh <último_backup>`
5. Verificar: `docker compose up -d` (todos os serviços)

### Cenário 2: Disco do host cheio

1. Identificar: `df -h` + `docker system df`
2. Limpar: `docker system prune -f` + rotacionar logs
3. Verificar integridade: `docker compose exec mariadb mariadb -e "CHECK TABLE ragnarok.login, ragnarok.char_"`
4. Se corrompido: restaurar do backup

### Cenário 3: Perda total do host

1. Provisionar novo servidor: Ubuntu 24.04
2. Clonar repositório + executar `setup.sh`
3. Copiar `.env` do backup ou reconfigurer
4. Transferir último backup (de storage externo, se disponível)
5. `docker compose up -d` → Restaurar backup → Verificar healthchecks

## Recomendações

- **Armazenamento externo**: Considere copiar backups para storage externo (S3, GCS, SFTP remoto) para proteção contra perda total do host
- **Teste mensal**: Execute um restore de teste mensal em ambiente isolado
- **Monitorar espaço**: Configure alerta no Zabbix para disco < 10% (já configurado como "Disaster")
- **Não confie apenas em volumes Docker**: Os volumes existem no mesmo disco — perda do disco = perda dos backups locais
