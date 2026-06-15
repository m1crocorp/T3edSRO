-- =============================================================================
-- 00-setup-users.sql
-- Inicialização de bancos de dados e usuários para infraestrutura rAthena
--
-- Este script é executado pelo 00-init.sh (NÃO diretamente pelo docker-entrypoint)
-- pois a imagem oficial mariadb:11.4 NÃO suporta substituição de variáveis de
-- ambiente em scripts .sql. O shell script injeta as senhas antes de executar.
--
-- Variáveis substituídas pelo 00-init.sh:
--   ${RATHENA_DB_PASSWORD}  - senha do usuário rathena
--   ${BACKUP_DB_PASSWORD}   - senha do usuário rathena_backup
--   ${FLUXCP_DB_PASSWORD}   - senha do usuário fluxcp
--   ${ZBX_DB_PASSWORD}      - senha do usuário zabbix
--
-- Requirements: 3.3, 3.5, 3.6, 3.12, 5.11
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Segurança: Remover banco test e usuários anônimos (Req 3.12)
-- -----------------------------------------------------------------------------
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
DELETE FROM mysql.global_priv WHERE User='';
-- Keep root@'%' for inter-container access (required by Zabbix Server init)
-- DELETE FROM mysql.global_priv WHERE User='root' AND Host NOT IN ('localhost', '127.0.0.1', '::1');

-- -----------------------------------------------------------------------------
-- Criar bancos de dados (Req 3.3)
-- Charset utf8mb4 com collation utf8mb4_general_ci para compatibilidade rAthena
-- -----------------------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS `ragnarok` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE IF NOT EXISTS `ragnarok_log` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;
CREATE DATABASE IF NOT EXISTS `zabbix` CHARACTER SET utf8mb4 COLLATE utf8mb4_general_ci;

-- -----------------------------------------------------------------------------
-- Usuário: rathena (Req 3.5)
-- Propósito: Operação dos servidores rAthena (Login, Char, Map)
-- Privilégios: SELECT, INSERT, UPDATE, DELETE em ragnarok e ragnarok_log
-- -----------------------------------------------------------------------------
CREATE USER IF NOT EXISTS 'rathena'@'%' IDENTIFIED BY '${RATHENA_DB_PASSWORD}';
GRANT SELECT, INSERT, UPDATE, DELETE ON `ragnarok`.* TO 'rathena'@'%';
GRANT SELECT, INSERT, UPDATE, DELETE ON `ragnarok_log`.* TO 'rathena'@'%';

-- -----------------------------------------------------------------------------
-- Usuário: rathena_backup (Req 3.6)
-- Propósito: Backup via mariadb-dump (--single-transaction --routines --triggers --events)
-- Privilégios: SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER em ragnarok e ragnarok_log
-- -----------------------------------------------------------------------------
CREATE USER IF NOT EXISTS 'rathena_backup'@'%' IDENTIFIED BY '${BACKUP_DB_PASSWORD}';
GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER ON `ragnarok`.* TO 'rathena_backup'@'%';
GRANT SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER ON `ragnarok_log`.* TO 'rathena_backup'@'%';

-- -----------------------------------------------------------------------------
-- Usuário: fluxcp (Req 3.5)
-- Propósito: Painel web FluxCP (registro de jogadores, gerenciamento de contas)
-- Privilégios: SELECT, INSERT, UPDATE, DELETE apenas no banco ragnarok
-- -----------------------------------------------------------------------------
CREATE USER IF NOT EXISTS 'fluxcp'@'%' IDENTIFIED BY '${FLUXCP_DB_PASSWORD}';
GRANT SELECT, INSERT, UPDATE, DELETE, CREATE TEMPORARY TABLES ON `ragnarok`.* TO 'fluxcp'@'%';
GRANT SELECT ON `ragnarok_log`.* TO 'fluxcp'@'%';

-- -----------------------------------------------------------------------------
-- Usuário: zabbix (Req 5.11)
-- Propósito: Zabbix Server - banco isolado para monitoramento
-- Privilégios: ALL PRIVILEGES no banco zabbix (isolado dos dados do jogo)
-- -----------------------------------------------------------------------------
CREATE USER IF NOT EXISTS 'zabbix'@'%' IDENTIFIED BY '${ZBX_DB_PASSWORD}';
GRANT ALL PRIVILEGES ON `zabbix`.* TO 'zabbix'@'%';

-- -----------------------------------------------------------------------------
-- Aplicar privilégios
-- -----------------------------------------------------------------------------
FLUSH PRIVILEGES;
