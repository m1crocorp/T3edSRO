#!/bin/bash
# MariaDB Entrypoint Wrapper
# Calcula dinamicamente innodb_buffer_pool_size com base na memória alocada ao container.
# - Copia custom.cnf para local gravável (/etc/mysql/conf.d/ local overlay)
# - Lê o limite de memória do cgroup (v2 ou v1)
# - Calcula 50% para buffer pool
# - Aplica mínimo de 128MB
# - Executa o entrypoint oficial do MariaDB
#
# Requirements: 3.9, 3.14

set -uo pipefail

readonly CUSTOM_CNF_SRC="/etc/mysql/conf.d.ro/custom.cnf"
readonly CUSTOM_CNF_DST="/etc/mysql/conf.d/custom.cnf"
readonly MIN_BUFFER=134217728  # 128MB em bytes
readonly DEFAULT_MEMORY=2147483648  # 2GB padrão quando sem limite

log() {
    echo "[mariadb-wrapper] $*"
}

log_error() {
    echo "[mariadb-wrapper] ERROR: $*" >&2
}

get_memory_limit() {
    local mem_limit=""

    if [ -f /sys/fs/cgroup/memory.max ]; then
        mem_limit=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || true)
    elif [ -f /sys/fs/cgroup/memory/memory.limit_in_bytes ]; then
        mem_limit=$(cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || true)
    fi

    if [ -z "$mem_limit" ] || [ "$mem_limit" = "max" ]; then
        echo "$DEFAULT_MEMORY"
        return
    fi

    if ! [[ "$mem_limit" =~ ^[0-9]+$ ]]; then
        log_error "Valor de memória inválido: '$mem_limit', usando padrão ${DEFAULT_MEMORY}"
        echo "$DEFAULT_MEMORY"
        return
    fi

    # cgroup v1 sem limite real retorna ~9.2 exabytes
    if [ "$mem_limit" -gt 8589934592 ]; then
        echo "$DEFAULT_MEMORY"
        return
    fi

    echo "$mem_limit"
}

calculate_buffer_pool() {
    local memory_limit="$1"
    local buffer_pool=$((memory_limit / 2))

    if [ "$buffer_pool" -lt "$MIN_BUFFER" ]; then
        buffer_pool=$MIN_BUFFER
    fi

    echo "$buffer_pool"
}

# --- Main ---

# Copiar custom.cnf do mount read-only para local gravável
if [ -f "$CUSTOM_CNF_SRC" ]; then
    cp "$CUSTOM_CNF_SRC" "$CUSTOM_CNF_DST"
    log "Copiado custom.cnf para diretório gravável"
fi

memory_limit=$(get_memory_limit)
buffer_pool=$(calculate_buffer_pool "$memory_limit")
buffer_mb=$((buffer_pool / 1048576))
memory_mb=$((memory_limit / 1048576))

if [ -f "$CUSTOM_CNF_DST" ]; then
    sed -i "s/innodb_buffer_pool_size = .*/innodb_buffer_pool_size = ${buffer_mb}M/" "$CUSTOM_CNF_DST"
    log "Memory limit: ${memory_mb}MB | Buffer pool: ${buffer_mb}M (50% of available)"
else
    log "Memory limit: ${memory_mb}MB | Buffer pool: using default (custom.cnf not found)"
fi

exec docker-entrypoint.sh "$@"
