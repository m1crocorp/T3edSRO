#!/bin/bash
# MariaDB Entrypoint Wrapper
# Calcula dinamicamente innodb_buffer_pool_size com base na memória alocada ao container.
# - Lê o limite de memória do cgroup (v2 ou v1)
# - Calcula 50% para buffer pool
# - Aplica mínimo de 128MB
# - Atualiza custom.cnf via sed
# - Executa o entrypoint oficial do MariaDB
#
# Requirements: 3.9, 3.14

set -euo pipefail

readonly CUSTOM_CNF="/etc/mysql/conf.d/custom.cnf"
readonly MIN_BUFFER=134217728  # 128MB em bytes
readonly DEFAULT_MEMORY=2147483648  # 2GB padrão quando sem limite

# Função para log com timestamp
log() {
    echo "[mariadb-wrapper] $*"
}

# Função para log de erro
log_error() {
    echo "[mariadb-wrapper] ERROR: $*" >&2
}

# Lê o limite de memória do cgroup (v2 primeiro, fallback para v1)
get_memory_limit() {
    local mem_limit=""

    if [ -f /sys/fs/cgroup/memory.max ]; then
        # cgroups v2
        mem_limit=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)
    elif [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        # cgroups v1
        mem_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || true)
    fi

    # cgroup v2 retorna "max" quando não há limite definido
    # cgroup v1 retorna valor muito alto (9223372036854771712) quando sem limite
    if [ -z "$mem_limit" ] || [ "$mem_limit" = "max" ]; then
        echo "$DEFAULT_MEMORY"
        return
    fi

    # Valida que é um número
    if ! [[ "$mem_limit" =~ ^[0-9]+$ ]]; then
        log_error "Valor de memória inválido: '$mem_limit', usando padrão ${DEFAULT_MEMORY}"
        echo "$DEFAULT_MEMORY"
        return
    fi

    # cgroup v1 sem limite real retorna ~9.2 exabytes; tratar como sem limite
    if [ "$mem_limit" -gt 8589934592 ]; then
        echo "$DEFAULT_MEMORY"
        return
    fi

    echo "$mem_limit"
}

# Calcula o buffer pool (50% da memória, mínimo 128MB)
calculate_buffer_pool() {
    local memory_limit="$1"
    local buffer_pool

    buffer_pool=$((memory_limit / 2))

    if [ "$buffer_pool" -lt "$MIN_BUFFER" ]; then
        buffer_pool=$MIN_BUFFER
    fi

    echo "$buffer_pool"
}

# Atualiza custom.cnf com o novo valor de buffer pool
update_config() {
    local buffer_mb="$1"

    if [ ! -f "$CUSTOM_CNF" ]; then
        log_error "Arquivo de configuração não encontrado: $CUSTOM_CNF"
        log "Continuando sem ajuste dinâmico do buffer pool"
        return 1
    fi

    sed -i "s/innodb_buffer_pool_size = .*/innodb_buffer_pool_size = ${buffer_mb}M/" "$CUSTOM_CNF"
}

# --- Main ---

memory_limit=$(get_memory_limit)
buffer_pool=$(calculate_buffer_pool "$memory_limit")

# Converte para MB para o arquivo de configuração
buffer_mb=$((buffer_pool / 1048576))
memory_mb=$((memory_limit / 1048576))

if update_config "$buffer_mb"; then
    log "Memory limit: ${memory_mb}MB | Buffer pool: ${buffer_mb}M (50% of available)"
else
    log "Memory limit: ${memory_mb}MB | Buffer pool: using default from custom.cnf"
fi

exec docker-entrypoint.sh "$@"
