#!/bin/bash
# ============================================================
# rAthena Server Infrastructure - Restore Script (restore.sh)
# ============================================================
# Restaura o banco de dados rAthena a partir de um backup .sql.gz
#
# Etapas:
#   1. Para serviços rAthena (login, char, map)
#   2. Valida arquivo de backup (existência + integridade gzip)
#   3. Restaura banco de dados via gunzip | mariadb
#   4. Verifica integridade (CHECK TABLE nas tabelas principais)
#   5. Reinicia serviços na ordem correta
#
# RTO: <15 minutos para bancos de até 5GB
# Para bancos >5GB: ~3 minutos por GB adicional
#
# Uso: sudo bash scripts/restore.sh <arquivo_backup.sql.gz>
#
# Exemplos:
#   sudo bash scripts/restore.sh /backups/rathena_db_2025-01-15_040000.sql.gz
#   sudo bash scripts/restore.sh ./rathena_db_2025-01-15_040000.sql.gz
# ============================================================

set -euo pipefail

# ------------------------------------------------------------
# Configuração
# ------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="/var/log/rathena"
LOG_FILE="${LOG_DIR}/restore-$(date +%Y%m%d_%H%M%S).log"
COMPOSE_FILE="${PROJECT_DIR}/docker-compose.yml"

# Tabelas principais para verificação de integridade
MAIN_TABLES=("login" "char_" "inventory" "guild")

# Serviços rAthena (ordem de parada: map -> char -> login)
SERVICES_STOP=("map-server" "char-server" "login-server")
# Ordem de inicialização: login -> char -> map (healthchecks garantem sequência)
SERVICES_START=("login-server" "char-server" "map-server")

# Carregar variáveis de ambiente do .env
ENV_FILE="${PROJECT_DIR}/.env"

# ------------------------------------------------------------
# Cores e formatação
# ------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ------------------------------------------------------------
# Funções de logging
# ------------------------------------------------------------
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"
    echo -e "${timestamp} [${level}] ${message}" | tee -a "${LOG_FILE}"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
    log "INFO" "$*"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
    log "OK" "$*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
    log "WARN" "$*"
}

log_error() {
    echo -e "${RED}[ERRO]${NC} $*"
    log "ERROR" "$*"
}

log_step() {
    echo -e "${CYAN}[STEP]${NC} $*"
    log "STEP" "$*"
}

# ------------------------------------------------------------
# Funções utilitárias
# ------------------------------------------------------------

# Calcula e exibe estimativa de tempo de restauração
estimate_restore_time() {
    local file_size_bytes="$1"
    local file_size_gb

    # Converter para GB (com casas decimais)
    file_size_gb=$(awk "BEGIN {printf \"%.2f\", ${file_size_bytes} / 1073741824}")

    # Estimativa: compressão típica gzip ~5x, então banco real ~5x maior
    # Para até 5GB comprimido (~25GB real): <15 minutos
    # Acima de 5GB: ~3 minutos por GB adicional
    local estimated_minutes

    if awk "BEGIN {exit !(${file_size_gb} <= 5)}"; then
        estimated_minutes=15
    else
        # Base 15min + 3min por GB acima de 5GB
        local extra_gb
        extra_gb=$(awk "BEGIN {printf \"%.0f\", ${file_size_gb} - 5}")
        estimated_minutes=$((15 + extra_gb * 3))
    fi

    log_info "Tamanho do backup: ${file_size_gb} GB (comprimido)"
    log_info "Tempo estimado de restauração: ~${estimated_minutes} minutos"

    # Se >5GB, registrar aviso especial
    if awk "BEGIN {exit !(${file_size_gb} > 5)}"; then
        log_warn "Banco grande detectado (>${file_size_gb}GB). O progresso será registrado no log."
        log_warn "Acompanhe: tail -f ${LOG_FILE}"
    fi

    echo "${estimated_minutes}"
}

# Calcula tempo decorrido de forma legível
elapsed_time() {
    local start="$1"
    local end
    end="$(date +%s)"
    local diff=$((end - start))
    local minutes=$((diff / 60))
    local seconds=$((diff % 60))
    echo "${minutes}m ${seconds}s"
}

# Carrega variáveis de ambiente para conexão com o banco
load_env() {
    if [[ -f "${ENV_FILE}" ]]; then
        # Exportar variáveis necessárias (ignorando comentários e linhas vazias)
        set -a
        # shellcheck source=/dev/null
        source <(grep -v '^\s*#' "${ENV_FILE}" | grep -v '^\s*$')
        set +a
    else
        log_error "Arquivo .env não encontrado em ${ENV_FILE}"
        log_error "Execute setup.sh primeiro ou copie .env.example para .env"
        exit 1
    fi
}

# Verifica se docker compose está acessível
check_docker_compose() {
    if ! docker compose version &>/dev/null; then
        log_error "Docker Compose não encontrado ou não funcional."
        log_error "Instale via: sudo bash scripts/setup.sh"
        exit 1
    fi
}

# Verifica se o container MariaDB está rodando
check_mariadb_running() {
    if ! docker compose -f "${COMPOSE_FILE}" ps mariadb --format '{{.State}}' 2>/dev/null | grep -q "running"; then
        log_error "Container MariaDB não está rodando."
        log_error "Execute: docker compose up -d mariadb"
        exit 1
    fi
}

# ------------------------------------------------------------
# Etapa 1: Validação do arquivo de backup
# ------------------------------------------------------------
validate_backup_file() {
    local backup_file="$1"

    log_step "Etapa 1/5: Validando arquivo de backup..."

    # Verificar existência
    if [[ ! -f "${backup_file}" ]]; then
        log_error "Arquivo de backup não encontrado: ${backup_file}"
        exit 1
    fi

    # Verificar se é legível
    if [[ ! -r "${backup_file}" ]]; then
        log_error "Sem permissão de leitura no arquivo: ${backup_file}"
        exit 1
    fi

    # Verificar extensão
    if [[ "${backup_file}" != *.sql.gz ]]; then
        log_warn "Extensão inesperada. Esperado: .sql.gz"
        log_warn "Tentando validar mesmo assim..."
    fi

    # Verificar integridade gzip
    log_info "Verificando integridade gzip (gunzip -t)..."
    if ! gunzip -t "${backup_file}" 2>/dev/null; then
        log_error "Arquivo de backup corrompido (falha na verificação gzip)."
        log_error "O arquivo pode estar incompleto ou danificado."
        exit 1
    fi

    # Obter tamanho do arquivo
    local file_size
    file_size=$(stat -c %s "${backup_file}" 2>/dev/null || stat -f %z "${backup_file}" 2>/dev/null)

    if [[ -z "${file_size}" ]] || [[ "${file_size}" -eq 0 ]]; then
        log_error "Arquivo de backup está vazio."
        exit 1
    fi

    log_success "Arquivo de backup válido: ${backup_file}"

    # Estimar tempo de restauração
    estimate_restore_time "${file_size}"
}

# ------------------------------------------------------------
# Etapa 2: Parar serviços rAthena
# ------------------------------------------------------------
stop_rathena_services() {
    log_step "Etapa 2/5: Parando serviços rAthena..."

    log_info "Parando login-server, char-server, map-server..."
    docker compose -f "${COMPOSE_FILE}" stop map-server char-server login-server

    # Verificar que todos foram parados
    for service in "${SERVICES_STOP[@]}"; do
        if docker compose -f "${COMPOSE_FILE}" ps "${service}" --format '{{.State}}' 2>/dev/null | grep -q "running"; then
            log_warn "${service} ainda está rodando. Tentando parar novamente..."
            docker compose -f "${COMPOSE_FILE}" stop "${service}"
        fi
        log_success "${service} parado."
    done

    log_success "Todos os serviços rAthena parados."
}

# ------------------------------------------------------------
# Etapa 3: Restaurar banco de dados
# ------------------------------------------------------------
restore_database() {
    local backup_file="$1"

    log_step "Etapa 3/5: Restaurando banco de dados..."

    local start_time
    start_time="$(date +%s)"

    # Obter credenciais do .env
    local db_user="root"
    local db_pass="${MARIADB_ROOT_PASSWORD:-}"
    local db_name="${RATHENA_DB_NAME:-ragnarok}"

    if [[ -z "${db_pass}" ]]; then
        log_error "MARIADB_ROOT_PASSWORD não definida no .env"
        exit 1
    fi

    log_info "Banco de destino: ${db_name}"
    log_info "Iniciando restauração (isso pode levar vários minutos)..."

    # Restaurar via gunzip | mariadb dentro do container
    # Usar pv para progresso se disponível, senão gunzip direto
    local restore_rc=0
    if command -v pv &>/dev/null; then
        local file_size
        file_size=$(stat -c %s "${backup_file}" 2>/dev/null || stat -f %z "${backup_file}" 2>/dev/null)
        pv -p -t -e -r "${backup_file}" | gunzip | \
            docker compose -f "${COMPOSE_FILE}" exec -T mariadb \
            mariadb -u"${db_user}" -p"${db_pass}" "${db_name}" 2>> "${LOG_FILE}" || restore_rc=$?
    else
        gunzip -c "${backup_file}" | \
            docker compose -f "${COMPOSE_FILE}" exec -T mariadb \
            mariadb -u"${db_user}" -p"${db_pass}" "${db_name}" 2>> "${LOG_FILE}" || restore_rc=$?
    fi

    if [[ ${restore_rc} -ne 0 ]]; then
        log_error "Falha na restauração do banco de dados (exit code: ${restore_rc})"
        log_error "Verifique o log: ${LOG_FILE}"
        exit 1
    fi

    local duration
    duration="$(elapsed_time "${start_time}")"
    log_success "Banco de dados restaurado com sucesso em ${duration}."
}

# ------------------------------------------------------------
# Etapa 4: Verificar integridade das tabelas
# ------------------------------------------------------------
verify_integrity() {
    log_step "Etapa 4/5: Verificando integridade das tabelas..."

    local db_user="root"
    local db_pass="${MARIADB_ROOT_PASSWORD:-}"
    local db_name="${RATHENA_DB_NAME:-ragnarok}"
    local all_ok=true

    for table in "${MAIN_TABLES[@]}"; do
        log_info "Verificando tabela: ${table}..."

        local result
        result=$(docker compose -f "${COMPOSE_FILE}" exec -T mariadb \
            mariadb -u"${db_user}" -p"${db_pass}" "${db_name}" \
            -N -e "CHECK TABLE \`${table}\`;" 2>/dev/null | tail -1)

        if echo "${result}" | grep -qi "OK"; then
            log_success "Tabela ${table}: OK"
        elif echo "${result}" | grep -qi "doesn't exist"; then
            log_warn "Tabela ${table}: não encontrada (pode ser esperado dependendo do backup)"
        else
            log_error "Tabela ${table}: PROBLEMA DETECTADO"
            log_error "Resultado: ${result}"
            all_ok=false
        fi
    done

    if [[ "${all_ok}" == "true" ]]; then
        log_success "Verificação de integridade concluída: todas as tabelas OK."
    else
        log_warn "Algumas tabelas apresentaram problemas. Verifique o log."
        log_warn "Considere executar REPAIR TABLE manualmente se necessário."
    fi
}

# ------------------------------------------------------------
# Etapa 5: Reiniciar serviços rAthena
# ------------------------------------------------------------
start_rathena_services() {
    log_step "Etapa 5/5: Reiniciando serviços rAthena..."

    # Iniciar serviços na ordem correta (login -> char -> map)
    # docker compose up -d respeita as dependências e healthchecks
    log_info "Iniciando serviços: login-server char-server map-server..."
    docker compose -f "${COMPOSE_FILE}" up -d login-server char-server map-server

    # Aguardar cada serviço ficar saudável
    for service in "${SERVICES_START[@]}"; do
        log_info "Aguardando ${service} ficar healthy..."
        local wait_count=0
        local max_wait=120

        while [[ ${wait_count} -lt ${max_wait} ]]; do
            local health_status
            health_status=$(docker compose -f "${COMPOSE_FILE}" ps "${service}" --format '{{.Health}}' 2>/dev/null || echo "unknown")

            if [[ "${health_status}" == "healthy" ]]; then
                log_success "${service} está healthy."
                break
            fi

            sleep 5
            wait_count=$((wait_count + 5))

            # Log de progresso a cada 30s
            if [[ $((wait_count % 30)) -eq 0 ]]; then
                log_info "${service}: aguardando healthcheck (${wait_count}s/${max_wait}s)..."
            fi
        done

        if [[ ${wait_count} -ge ${max_wait} ]]; then
            log_warn "${service} não ficou healthy em ${max_wait}s. Verifique logs:"
            log_warn "  docker compose logs ${service}"
        fi
    done

    log_success "Serviços rAthena reiniciados."
}

# ------------------------------------------------------------
# Exibir uso do script
# ------------------------------------------------------------
usage() {
    echo "Uso: $0 <arquivo_backup.sql.gz>"
    echo ""
    echo "Restaura o banco de dados rAthena a partir de um backup comprimido."
    echo ""
    echo "Argumentos:"
    echo "  arquivo_backup.sql.gz   Caminho para o arquivo de backup (.sql.gz)"
    echo ""
    echo "Exemplos:"
    echo "  $0 /backups/rathena_db_2025-01-15_040000.sql.gz"
    echo "  $0 ./rathena_db_2025-01-15_040000.sql.gz"
    echo ""
    echo "O script irá:"
    echo "  1. Validar o arquivo de backup (existência + integridade gzip)"
    echo "  2. Parar os serviços rAthena (map, char, login)"
    echo "  3. Restaurar o banco de dados"
    echo "  4. Verificar integridade das tabelas principais"
    echo "  5. Reiniciar os serviços na ordem correta"
    echo ""
    echo "RTO: <15 minutos para bancos de até 5GB"
    echo "Log: ${LOG_DIR}/restore-YYYYMMDD_HHMMSS.log"
    exit 1
}

# ------------------------------------------------------------
# Cleanup em caso de erro — reiniciar serviços automaticamente
# ------------------------------------------------------------
cleanup_on_error() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        echo ""
        log_error "Restauração interrompida com erro (exit code: ${exit_code})."
        log_error "Log completo: ${LOG_FILE}"
        echo ""
        log_warn "Tentando reiniciar serviços rAthena para evitar downtime prolongado..."

        # Tentar reiniciar serviços automaticamente (best-effort)
        if docker compose -f "${COMPOSE_FILE}" up -d login-server char-server map-server 2>/dev/null; then
            log_success "Serviços rAthena reiniciados automaticamente (estado anterior ao restore)."
        else
            log_error "Falha ao reiniciar serviços automaticamente."
            log_warn "Para reiniciar manualmente:"
            log_warn "  cd ${PROJECT_DIR}"
            log_warn "  docker compose up -d login-server char-server map-server"
        fi
    fi
}

# ------------------------------------------------------------
# Execução principal
# ------------------------------------------------------------
main() {
    # Verificar argumento
    if [[ $# -lt 1 ]] || [[ "$1" == "-h" ]] || [[ "$1" == "--help" ]]; then
        usage
    fi

    local backup_file="$1"

    # Converter para caminho absoluto se necessário
    if [[ "${backup_file}" != /* ]]; then
        backup_file="$(cd "$(dirname "${backup_file}")" && pwd)/$(basename "${backup_file}")"
    fi

    # Criar diretório de log
    mkdir -p "${LOG_DIR}"

    # Registrar trap para cleanup em caso de erro
    trap cleanup_on_error EXIT

    echo "============================================================"
    echo " rAthena Server - Restauração de Backup"
    echo "============================================================"
    echo ""
    log_info "Início: $(date '+%Y-%m-%d %H:%M:%S')"
    log_info "Arquivo: ${backup_file}"
    log_info "Log: ${LOG_FILE}"
    echo ""

    local total_start
    total_start="$(date +%s)"

    # Carregar configurações
    load_env

    # Pré-requisitos
    check_docker_compose
    check_mariadb_running
    echo ""

    # Etapa 1: Validar backup
    validate_backup_file "${backup_file}"
    echo ""

    # Etapa 2: Parar serviços
    stop_rathena_services
    echo ""

    # Etapa 3: Restaurar banco
    restore_database "${backup_file}"
    echo ""

    # Etapa 4: Verificar integridade
    verify_integrity
    echo ""

    # Etapa 5: Reiniciar serviços
    start_rathena_services
    echo ""

    # Resumo final
    local total_duration
    total_duration="$(elapsed_time "${total_start}")"

    # Limpar trap de erro (sucesso)
    trap - EXIT

    echo "============================================================"
    log_success "Restauração concluída com sucesso!"
    echo ""
    echo " Tempo total: ${total_duration}"
    echo " Arquivo restaurado: $(basename "${backup_file}")"
    echo " Log completo: ${LOG_FILE}"
    echo ""
    echo " Verificação pós-restore:"
    echo "   docker compose ps"
    echo "   docker compose logs --tail=20 login-server"
    echo "============================================================"

    log "INFO" "Restauração finalizada em ${total_duration}"
}

# Executar
main "$@"
