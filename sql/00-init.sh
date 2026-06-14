#!/bin/bash
# =============================================================================
# 00-init.sh
# Orquestra a inicialização do banco de dados MariaDB para a infraestrutura rAthena.
#
# Este script é executado automaticamente pela imagem oficial mariadb:11.4 quando
# montado em /docker-entrypoint-initdb.d/. Ele é executado APENAS na primeira
# inicialização (quando o datadir está vazio).
#
# Responsabilidades:
#   1. Verificar se bancos/usuários já existem (idempotência)
#   2. Executar 00-setup-users.sql com senhas injetadas via variáveis de ambiente
#   3. Baixar e executar schemas oficiais do rAthena (main.sql, logs.sql)
#
# Variáveis de ambiente esperadas:
#   MARIADB_ROOT_PASSWORD  - senha root do MariaDB (definida pelo container)
#   RATHENA_DB_PASSWORD    - senha do usuário rathena
#   BACKUP_DB_PASSWORD     - senha do usuário rathena_backup
#   FLUXCP_DB_PASSWORD     - senha do usuário fluxcp
#   ZBX_DB_PASSWORD        - senha do usuário zabbix
#
# Requirements: 3.3, 3.5, 3.6, 3.12, 5.11
# =============================================================================

set -euo pipefail

# Diretório onde os scripts de inicialização estão montados
INIT_DIR="/docker-entrypoint-initdb.d"
SQL_DIR="${INIT_DIR}"

# URL base para schemas oficiais do rAthena
RATHENA_SQL_BASE_URL="https://raw.githubusercontent.com/rathena/rathena/master/sql-files"

# Cores para output (se terminal suportar)
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[init]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[init][WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[init][ERROR]${NC} $1"
}

# -----------------------------------------------------------------------------
# Variáveis de ambiente com valores padrão (NÃO usar em produção!)
# -----------------------------------------------------------------------------
RATHENA_DB_PASSWORD="${RATHENA_DB_PASSWORD:-rathena_change_me}"
BACKUP_DB_PASSWORD="${BACKUP_DB_PASSWORD:-backup_change_me}"
FLUXCP_DB_PASSWORD="${FLUXCP_DB_PASSWORD:-fluxcp_change_me}"
ZBX_DB_PASSWORD="${ZBX_DB_PASSWORD:-zabbix_change_me}"

# Verificar se senhas padrão estão sendo usadas
if [[ "${RATHENA_DB_PASSWORD}" == *"change_me"* ]] || \
   [[ "${BACKUP_DB_PASSWORD}" == *"change_me"* ]] || \
   [[ "${FLUXCP_DB_PASSWORD}" == *"change_me"* ]] || \
   [[ "${ZBX_DB_PASSWORD}" == *"change_me"* ]]; then
    log_warn "Senhas padrão detectadas! Configure senhas fortes no .env para produção."
fi

# -----------------------------------------------------------------------------
# Função: Verificar se a inicialização já foi executada (idempotência)
# -----------------------------------------------------------------------------
check_already_initialized() {
    # Verifica se o banco ragnarok já existe e tem tabelas
    local db_exists
    db_exists=$(mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -N -e \
        "SELECT COUNT(*) FROM information_schema.SCHEMATA WHERE SCHEMA_NAME='ragnarok';" 2>/dev/null || echo "0")

    if [[ "${db_exists}" -gt 0 ]]; then
        # Verificar se já tem tabelas (indica que schemas já foram aplicados)
        local table_count
        table_count=$(mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" -N -e \
            "SELECT COUNT(*) FROM information_schema.TABLES WHERE TABLE_SCHEMA='ragnarok';" 2>/dev/null || echo "0")

        if [[ "${table_count}" -gt 0 ]]; then
            log_info "Banco 'ragnarok' já inicializado (${table_count} tabelas). Pulando inicialização."
            return 0
        fi
    fi
    return 1
}

# -----------------------------------------------------------------------------
# Função: Executar setup de usuários e bancos
# -----------------------------------------------------------------------------
setup_users_and_databases() {
    log_info "Criando bancos de dados e usuários..."

    local setup_sql="${SQL_DIR}/00-setup-users.sql"

    if [[ ! -f "${setup_sql}" ]]; then
        log_error "Arquivo ${setup_sql} não encontrado!"
        exit 1
    fi

    # Substituir placeholders de senha no SQL e executar
    sed -e "s|\${RATHENA_DB_PASSWORD}|${RATHENA_DB_PASSWORD}|g" \
        -e "s|\${BACKUP_DB_PASSWORD}|${BACKUP_DB_PASSWORD}|g" \
        -e "s|\${FLUXCP_DB_PASSWORD}|${FLUXCP_DB_PASSWORD}|g" \
        -e "s|\${ZBX_DB_PASSWORD}|${ZBX_DB_PASSWORD}|g" \
        "${setup_sql}" | mariadb -u root -p"${MARIADB_ROOT_PASSWORD}"

    log_info "Bancos e usuários criados com sucesso."
}

# -----------------------------------------------------------------------------
# Função: Baixar schema SQL do rAthena se não presente localmente
# -----------------------------------------------------------------------------
download_schema() {
    local filename="$1"
    local target="${SQL_DIR}/${filename}"

    if [[ -f "${target}" ]]; then
        log_info "Schema '${filename}' já presente localmente."
        return 0
    fi

    local url="${RATHENA_SQL_BASE_URL}/${filename}"
    log_info "Baixando schema '${filename}' de ${url}..."

    if command -v curl &>/dev/null; then
        if ! curl -fsSL -o "${target}" "${url}"; then
            log_error "Falha ao baixar ${filename} via curl."
            return 1
        fi
    elif command -v wget &>/dev/null; then
        if ! wget -q -O "${target}" "${url}"; then
            log_error "Falha ao baixar ${filename} via wget."
            return 1
        fi
    else
        log_error "Nem curl nem wget disponíveis para download dos schemas."
        return 1
    fi

    log_info "Schema '${filename}' baixado com sucesso."
    return 0
}

# -----------------------------------------------------------------------------
# Função: Executar schemas oficiais do rAthena
# -----------------------------------------------------------------------------
apply_rathena_schemas() {
    log_info "Aplicando schemas oficiais do rAthena..."

    # Schema principal (tabelas do jogo: login, char_, inventory, guild, etc.)
    if download_schema "main.sql"; then
        log_info "Executando main.sql no banco 'ragnarok'..."
        mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" ragnarok < "${SQL_DIR}/main.sql"
        log_info "main.sql aplicado com sucesso."
    else
        log_warn "Não foi possível obter main.sql. O banco será criado vazio."
        log_warn "Execute manualmente: mariadb ragnarok < main.sql"
    fi

    # Schema de logs (tabelas de auditoria: loginlog, picklog, zenylog, etc.)
    if download_schema "logs.sql"; then
        log_info "Executando logs.sql no banco 'ragnarok_log'..."
        mariadb -u root -p"${MARIADB_ROOT_PASSWORD}" ragnarok_log < "${SQL_DIR}/logs.sql"
        log_info "logs.sql aplicado com sucesso."
    else
        log_warn "Não foi possível obter logs.sql. O banco de logs será criado vazio."
        log_warn "Execute manualmente: mariadb ragnarok_log < logs.sql"
    fi
}

# =============================================================================
# EXECUÇÃO PRINCIPAL
# =============================================================================

log_info "=========================================="
log_info "Inicialização do banco de dados rAthena"
log_info "=========================================="

# Passo 1: Verificar idempotência
if check_already_initialized; then
    log_info "Inicialização já concluída anteriormente. Saindo."
    exit 0
fi

# Passo 2: Criar bancos e usuários via 00-setup-users.sql
setup_users_and_databases

# Passo 3: Baixar e aplicar schemas oficiais do rAthena
apply_rathena_schemas

log_info "=========================================="
log_info "Inicialização concluída com sucesso!"
log_info "=========================================="
