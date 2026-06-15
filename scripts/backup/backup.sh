#!/bin/bash
# =============================================================================
# rAthena Backup Script
# =============================================================================
# Executa backup do banco de dados MariaDB e arquivos de configuração.
# Projetado para rodar dentro do container backup (imagem mariadb:11.4).
#
# Variáveis de ambiente esperadas:
#   DB_HOST              - Host do MariaDB (default: mariadb)
#   DB_PORT              - Porta do MariaDB (default: 3306)
#   BACKUP_DB_USER       - Usuário de backup do banco
#   BACKUP_DB_PASSWORD   - Senha do usuário de backup
#   RATHENA_DB_NAME      - Nome do banco principal (default: ragnarok)
#   RATHENA_LOG_DB_NAME  - Nome do banco de logs (default: ragnarok_log)
#   BACKUP_RETENTION_DAYS - Dias de retenção (default: 30)
#   BACKUP_WEBHOOK_URL   - URL do webhook para notificação de falha (opcional)
#
# Volumes esperados:
#   /backups             - Diretório de destino dos backups
#   /rathena/conf        - Configurações do rAthena (read-only)
#   /rathena/npc/custom  - Scripts NPC customizados (read-only)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuração
# ---------------------------------------------------------------------------
DB_HOST="${DB_HOST:-mariadb}"
DB_PORT="${DB_PORT:-3306}"
BACKUP_DB_USER="${BACKUP_DB_USER:-rathena_backup}"
BACKUP_DB_PASSWORD="${BACKUP_DB_PASSWORD:-}"
RATHENA_DB_NAME="${RATHENA_DB_NAME:-ragnarok}"
RATHENA_LOG_DB_NAME="${RATHENA_LOG_DB_NAME:-ragnarok_log}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
BACKUP_WEBHOOK_URL="${BACKUP_WEBHOOK_URL:-}"

BACKUP_DIR="/backups"
LOG_FILE="${BACKUP_DIR}/backup.log"
TIMESTAMP=$(date +"%Y-%m-%d_%H%M%S")
DATE_ONLY=$(date +"%Y-%m-%d")

# Nomes dos arquivos de backup
DB_BACKUP_FILE="rathena_db_${TIMESTAMP}.sql.gz"
CONFIG_BACKUP_FILE="rathena_config_${DATE_ONLY}.tar.gz"

# ---------------------------------------------------------------------------
# Funções utilitárias
# ---------------------------------------------------------------------------

log() {
    local level="$1"
    shift
    local message="$*"
    local ts
    ts=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[${ts}] [${level}] ${message}" | tee -a "${LOG_FILE}"
}

log_info() {
    log "INFO" "$@"
}

log_error() {
    log "ERROR" "$@"
}

log_success() {
    log "SUCCESS" "$@"
}

# Calcula tamanho do arquivo em formato legível
file_size_human() {
    local file="$1"
    if [ -f "${file}" ]; then
        du -h "${file}" | cut -f1
    else
        echo "0"
    fi
}

# Envia notificação webhook em caso de falha
# Auto-detecta formato baseado no padrão da URL:
#   - Discord: POST JSON com {"content": "message"}
#   - Slack: POST JSON com {"text": "message"}
#   - Telegram: GET request com parâmetro text
send_failure_notification() {
    local exit_code="$1"
    local error_context="$2"

    if [ -z "${BACKUP_WEBHOOK_URL}" ]; then
        log_info "Webhook URL não configurada, pulando notificação"
        return 0
    fi

    # Obter últimas 20 linhas do log para contexto
    local last_lines=""
    if [ -f "${LOG_FILE}" ]; then
        last_lines=$(tail -20 "${LOG_FILE}" 2>/dev/null || echo "Não foi possível ler o log")
    fi

    local hostname
    hostname=$(hostname 2>/dev/null || echo "backup-container")
    local timestamp
    timestamp=$(date +"%Y-%m-%d %H:%M:%S UTC")

    # Montar mensagem base
    local message
    message="⚠️ Falha no Backup rAthena
Host: ${hostname}
Exit Code: ${exit_code}
Timestamp: ${timestamp}
Erro: ${error_context}

Últimas linhas do log:
${last_lines}"

    # Auto-detectar formato do webhook pela URL e enviar
    if echo "${BACKUP_WEBHOOK_URL}" | grep -qi "discord"; then
        # Discord: POST JSON com {"content": "message"}
        local payload
        # Escapar caracteres especiais para JSON
        local json_message
        json_message=$(printf '%s' "${message}" | sed 's/\\/\\\\/g; s/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
        payload="{\"content\":\"${json_message}\"}"

        log_info "Enviando notificação via Discord webhook"
        if command -v curl &>/dev/null; then
            curl -s -o /dev/null -w "%{http_code}" \
                -H "Content-Type: application/json" \
                -d "${payload}" \
                "${BACKUP_WEBHOOK_URL}" || log_error "Falha ao enviar webhook Discord"
        elif command -v wget &>/dev/null; then
            wget -q -O /dev/null \
                --header="Content-Type: application/json" \
                --post-data="${payload}" \
                "${BACKUP_WEBHOOK_URL}" || log_error "Falha ao enviar webhook Discord"
        else
            log_error "Nem curl nem wget disponíveis para enviar webhook"
        fi

    elif echo "${BACKUP_WEBHOOK_URL}" | grep -qi "slack"; then
        # Slack: POST JSON com {"text": "message"}
        local payload
        local json_message
        json_message=$(printf '%s' "${message}" | sed 's/\\/\\\\/g; s/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
        payload="{\"text\":\"${json_message}\"}"

        log_info "Enviando notificação via Slack webhook"
        if command -v curl &>/dev/null; then
            curl -s -o /dev/null -w "%{http_code}" \
                -H "Content-Type: application/json" \
                -d "${payload}" \
                "${BACKUP_WEBHOOK_URL}" || log_error "Falha ao enviar webhook Slack"
        elif command -v wget &>/dev/null; then
            wget -q -O /dev/null \
                --header="Content-Type: application/json" \
                --post-data="${payload}" \
                "${BACKUP_WEBHOOK_URL}" || log_error "Falha ao enviar webhook Slack"
        else
            log_error "Nem curl nem wget disponíveis para enviar webhook"
        fi

    elif echo "${BACKUP_WEBHOOK_URL}" | grep -qi "telegram"; then
        # Telegram: GET request com parâmetro text
        # URL esperada: https://api.telegram.org/bot<TOKEN>/sendMessage?chat_id=<CHAT_ID>
        local encoded_message
        encoded_message=$(printf '%s' "${message}" | sed 's/ /%20/g; s/\n/%0A/g; s/!/%21/g; s/#/%23/g; s/&/%26/g; s/⚠️/%E2%9A%A0%EF%B8%8F/g')

        # Construir URL com parâmetro text
        local telegram_url
        if echo "${BACKUP_WEBHOOK_URL}" | grep -q '?'; then
            telegram_url="${BACKUP_WEBHOOK_URL}&text=${encoded_message}"
        else
            telegram_url="${BACKUP_WEBHOOK_URL}?text=${encoded_message}"
        fi

        log_info "Enviando notificação via Telegram webhook"
        if command -v curl &>/dev/null; then
            curl -s -o /dev/null -w "%{http_code}" \
                -G "${BACKUP_WEBHOOK_URL}" \
                --data-urlencode "text=${message}" || log_error "Falha ao enviar webhook Telegram"
        elif command -v wget &>/dev/null; then
            wget -q -O /dev/null "${telegram_url}" || log_error "Falha ao enviar webhook Telegram"
        else
            log_error "Nem curl nem wget disponíveis para enviar webhook"
        fi

    else
        # Formato genérico: POST JSON com {"text": "message"}
        local payload
        local json_message
        json_message=$(printf '%s' "${message}" | sed 's/\\/\\\\/g; s/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
        payload="{\"text\":\"${json_message}\"}"

        log_info "Enviando notificação via webhook genérico"
        if command -v curl &>/dev/null; then
            curl -s -o /dev/null -w "%{http_code}" \
                -H "Content-Type: application/json" \
                -d "${payload}" \
                "${BACKUP_WEBHOOK_URL}" || log_error "Falha ao enviar webhook"
        elif command -v wget &>/dev/null; then
            wget -q -O /dev/null \
                --header="Content-Type: application/json" \
                --post-data="${payload}" \
                "${BACKUP_WEBHOOK_URL}" || log_error "Falha ao enviar webhook"
        else
            log_error "Nem curl nem wget disponíveis para enviar webhook"
        fi
    fi
}

# ---------------------------------------------------------------------------
# Validações iniciais
# ---------------------------------------------------------------------------

# Criar diretório de backup se não existir
mkdir -p "${BACKUP_DIR}"

log_info "=========================================="
log_info "Iniciando backup rAthena"
log_info "=========================================="
log_info "Host DB: ${DB_HOST}:${DB_PORT}"
log_info "Bancos: ${RATHENA_DB_NAME}, ${RATHENA_LOG_DB_NAME}"
log_info "Retenção: ${BACKUP_RETENTION_DAYS} dias"
log_info "Diretório: ${BACKUP_DIR}"

# Verificar conectividade com o banco
if ! mariadb -h "${DB_HOST}" -P "${DB_PORT}" -u "${BACKUP_DB_USER}" \
    -p"${BACKUP_DB_PASSWORD}" -e "SELECT 1;" &>/dev/null; then
    log_error "Não foi possível conectar ao MariaDB em ${DB_HOST}:${DB_PORT}"
    send_failure_notification "1" "Falha de conexão com o banco de dados"
    exit 1
fi

log_info "Conexão com MariaDB verificada com sucesso"

# ---------------------------------------------------------------------------
# Backup do Banco de Dados
# ---------------------------------------------------------------------------

BACKUP_SUCCESS=true
START_TIME=$(date +%s)

log_info "Iniciando dump do banco de dados..."

if mariadb-dump \
    -h "${DB_HOST}" \
    -P "${DB_PORT}" \
    -u "${BACKUP_DB_USER}" \
    -p"${BACKUP_DB_PASSWORD}" \
    --single-transaction \
    --routines \
    --triggers \
    --events \
    --databases "${RATHENA_DB_NAME}" "${RATHENA_LOG_DB_NAME}" \
    2>>"${LOG_FILE}" | gzip > "${BACKUP_DIR}/${DB_BACKUP_FILE}"; then

    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    DB_SIZE=$(file_size_human "${BACKUP_DIR}/${DB_BACKUP_FILE}")

    log_success "Backup do banco concluído com sucesso"
    log_info "Arquivo: ${DB_BACKUP_FILE}"
    log_info "Tamanho: ${DB_SIZE}"
    log_info "Duração: ${DURATION}s"
else
    END_TIME=$(date +%s)
    DURATION=$((END_TIME - START_TIME))
    BACKUP_SUCCESS=false

    log_error "Falha no dump do banco de dados"
    log_error "Duração até falha: ${DURATION}s"

    # Remover arquivo parcial se existir
    rm -f "${BACKUP_DIR}/${DB_BACKUP_FILE}"

    send_failure_notification "$?" "Falha no mariadb-dump"
fi

# ---------------------------------------------------------------------------
# Backup de Configurações
# ---------------------------------------------------------------------------

log_info "Iniciando backup de configurações..."

CONFIG_START_TIME=$(date +%s)

if tar czf "${BACKUP_DIR}/${CONFIG_BACKUP_FILE}" \
    -C / \
    rathena/conf \
    rathena/npc/custom \
    2>>"${LOG_FILE}"; then

    CONFIG_END_TIME=$(date +%s)
    CONFIG_DURATION=$((CONFIG_END_TIME - CONFIG_START_TIME))
    CONFIG_SIZE=$(file_size_human "${BACKUP_DIR}/${CONFIG_BACKUP_FILE}")

    log_success "Backup de configurações concluído com sucesso"
    log_info "Arquivo: ${CONFIG_BACKUP_FILE}"
    log_info "Tamanho: ${CONFIG_SIZE}"
    log_info "Duração: ${CONFIG_DURATION}s"
else
    CONFIG_END_TIME=$(date +%s)
    CONFIG_DURATION=$((CONFIG_END_TIME - CONFIG_START_TIME))
    BACKUP_SUCCESS=false

    log_error "Falha no backup de configurações"
    log_error "Duração até falha: ${CONFIG_DURATION}s"

    # Remover arquivo parcial se existir
    rm -f "${BACKUP_DIR}/${CONFIG_BACKUP_FILE}"

    send_failure_notification "$?" "Falha no backup de configurações (tar)"
fi

# ---------------------------------------------------------------------------
# Rotação de Backups Antigos
# ---------------------------------------------------------------------------

log_info "Executando rotação de backups (retenção: ${BACKUP_RETENTION_DAYS} dias)..."

DELETED_COUNT=0

# Remover backups de banco mais antigos que BACKUP_RETENTION_DAYS
while IFS= read -r old_file; do
    if [ -n "${old_file}" ]; then
        log_info "Removendo backup antigo: $(basename "${old_file}")"
        rm -f "${old_file}"
        DELETED_COUNT=$((DELETED_COUNT + 1))
    fi
done < <(find "${BACKUP_DIR}" -name "rathena_db_*.sql.gz" -type f -mtime "+${BACKUP_RETENTION_DAYS}" 2>/dev/null)

# Remover backups de configuração mais antigos que BACKUP_RETENTION_DAYS
while IFS= read -r old_file; do
    if [ -n "${old_file}" ]; then
        log_info "Removendo config backup antigo: $(basename "${old_file}")"
        rm -f "${old_file}"
        DELETED_COUNT=$((DELETED_COUNT + 1))
    fi
done < <(find "${BACKUP_DIR}" -name "rathena_config_*.tar.gz" -type f -mtime "+${BACKUP_RETENTION_DAYS}" 2>/dev/null)

log_info "Rotação concluída: ${DELETED_COUNT} arquivo(s) removido(s)"

# ---------------------------------------------------------------------------
# Resultado Final
# ---------------------------------------------------------------------------

TOTAL_END_TIME=$(date +%s)
TOTAL_DURATION=$((TOTAL_END_TIME - START_TIME))

log_info "=========================================="
if [ "${BACKUP_SUCCESS}" = true ]; then
    log_success "Backup completo finalizado com SUCESSO"
    log_info "Duração total: ${TOTAL_DURATION}s"
    log_info "=========================================="
    exit 0
else
    log_error "Backup finalizado com FALHAS"
    log_info "Duração total: ${TOTAL_DURATION}s"
    log_info "=========================================="
    send_failure_notification "1" "Backup finalizado com falhas - verifique o log"
    exit 1
fi
