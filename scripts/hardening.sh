#!/bin/bash
# =============================================================================
# hardening.sh - Script de Hardening do Servidor rAthena
# =============================================================================
# Configura proteções de segurança no host Ubuntu 24.04 LTS:
# - sysctl de rede (SYN cookies, reverse path filter, desabilitar IPv6)
# - Conntrack com timeout reduzido para mitigação de SYN flood
# - Hardening SSH (apenas chaves, sem root login)
# - Proteção do Docker socket
# - Rate limiting iptables nas portas rAthena (6900, 6121, 5121)
# - Remoção de pacotes desnecessários
# - Configuração de limites de arquivo
#
# Uso: sudo ./hardening.sh
# O script é idempotente — pode ser re-executado com segurança.
#
# Requirements: 8.1, 8.4, 8.8, 8.10, 8.11, 14.1, 14.2, 14.3, 14.4
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Constantes e configuração de logging
# -----------------------------------------------------------------------------
readonly LOG_FILE="/var/log/rathena-hardening.log"
readonly SCRIPT_NAME="hardening.sh"
readonly RATHENA_PORTS=(6900 6121 5121)
readonly RATHENA_NAMES=(rathena_login rathena_char rathena_map)

# Cria o diretório de log se não existir
mkdir -p "$(dirname "${LOG_FILE}")"

# Função de logging — envia para stdout e para arquivo de log
log() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[${level}] ${message}"
    echo "${timestamp} [${level}] [${SCRIPT_NAME}] ${message}" >> "${LOG_FILE}"
}

log_info()  { log "INFO"  "$@"; }
log_ok()    { log "OK"    "$@"; }
log_warn()  { log "WARN"  "$@"; }
log_error() { log "ERRO"  "$@"; }

# -----------------------------------------------------------------------------
# Verificação de privilégios
# -----------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo "[ERRO] Este script deve ser executado como root (sudo)."
    exit 1
fi

log_info "============================================"
log_info "Iniciando hardening do servidor rAthena"
log_info "============================================"

# -----------------------------------------------------------------------------
# 1. Configuração sysctl de rede
# Req 8.8: sysctl net.ipv4.tcp_syncookies=1, net.ipv4.conf.all.rp_filter=1
# Req 14.4: tcp_syncookies=1, tcp_max_syn_backlog=2048
# -----------------------------------------------------------------------------
configure_sysctl() {
    log_info "Configurando parâmetros sysctl de rede..."

    local sysctl_conf="/etc/sysctl.d/99-rathena-hardening.conf"

    cat > "${sysctl_conf}" <<'EOF'
# =============================================================================
# Hardening de rede para rAthena Server
# Gerado por hardening.sh - NÃO editar manualmente
# =============================================================================

# Proteção contra SYN flood (Req 14.4)
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048

# Reverse path filtering — anti-spoofing (Req 8.8)
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Desabilitar IPv6 (não utilizado neste ambiente)
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# Proteções adicionais de rede
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Conntrack — timeouts reduzidos para mitigação SYN flood (Req 14.4)
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 30
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 30
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_max = 131072
EOF

    # Garantir que o módulo nf_conntrack está carregado antes de aplicar
    if ! lsmod | grep -q nf_conntrack; then
        modprobe nf_conntrack 2>/dev/null || true
    fi

    sysctl -p "${sysctl_conf}" > /dev/null 2>&1 || {
        log_warn "Alguns parâmetros sysctl podem não estar disponíveis neste kernel."
        # Aplicar individualmente para não falhar em parâmetros não suportados
        while IFS= read -r line; do
            [[ "${line}" =~ ^#.*$ || -z "${line}" ]] && continue
            sysctl -w "${line}" > /dev/null 2>&1 || true
        done < "${sysctl_conf}"
    }

    log_ok "Parâmetros sysctl aplicados e persistidos em ${sysctl_conf}"
}

# -----------------------------------------------------------------------------
# 2. Hardening SSH
# Req 8.1: PasswordAuthentication no, PermitRootLogin no
# -----------------------------------------------------------------------------
configure_ssh() {
    log_info "Configurando hardening SSH..."

    local sshd_config="/etc/ssh/sshd_config"

    if [[ ! -f "${sshd_config}" ]]; then
        log_warn "Arquivo ${sshd_config} não encontrado. Pulando hardening SSH."
        return 0
    fi

    # Backup do arquivo original (apenas na primeira execução)
    if [[ ! -f "${sshd_config}.bak.hardening" ]]; then
        cp "${sshd_config}" "${sshd_config}.bak.hardening"
        log_info "Backup do sshd_config original criado."
    fi

    # Desabilitar autenticação por senha
    if grep -q "^PasswordAuthentication" "${sshd_config}"; then
        sed -i 's/^PasswordAuthentication.*/PasswordAuthentication no/' "${sshd_config}"
    elif grep -q "^#PasswordAuthentication" "${sshd_config}"; then
        sed -i 's/^#PasswordAuthentication.*/PasswordAuthentication no/' "${sshd_config}"
    else
        echo "PasswordAuthentication no" >> "${sshd_config}"
    fi

    # Desabilitar login root via SSH
    if grep -q "^PermitRootLogin" "${sshd_config}"; then
        sed -i 's/^PermitRootLogin.*/PermitRootLogin no/' "${sshd_config}"
    elif grep -q "^#PermitRootLogin" "${sshd_config}"; then
        sed -i 's/^#PermitRootLogin.*/PermitRootLogin no/' "${sshd_config}"
    else
        echo "PermitRootLogin no" >> "${sshd_config}"
    fi

    # Reiniciar SSH para aplicar configurações
    if systemctl is-active --quiet sshd 2>/dev/null; then
        systemctl reload sshd
        log_ok "SSH recarregado com novas configurações (sshd)."
    elif systemctl is-active --quiet ssh 2>/dev/null; then
        systemctl reload ssh
        log_ok "SSH recarregado com novas configurações (ssh)."
    else
        log_warn "Serviço SSH não encontrado ativo. Configurações serão aplicadas no próximo reinício."
    fi
}

# -----------------------------------------------------------------------------
# 3. Proteção do Docker socket
# Req 8.10: chmod 660, ownership root:docker
# -----------------------------------------------------------------------------
protect_docker_socket() {
    log_info "Protegendo Docker socket..."

    local docker_socket="/var/run/docker.sock"

    if [[ -S "${docker_socket}" ]]; then
        chmod 660 "${docker_socket}"
        chown root:docker "${docker_socket}"
        log_ok "Docker socket protegido (chmod 660, root:docker)."
    else
        log_warn "Docker socket não encontrado em ${docker_socket}. Pulando."
    fi
}

# -----------------------------------------------------------------------------
# 4. Rate limiting iptables nas portas rAthena
# Req 8.11: hashlimit 10 novas conexões/sec por IP (burst 15)
# Req 14.1: Rate limiting 10 novas conexões/s por IP
# Req 14.2: connlimit 20 conexões simultâneas por IP
# Req 14.3: DROP sem resposta
# -----------------------------------------------------------------------------
configure_iptables() {
    log_info "Configurando rate limiting iptables..."

    # Garantir que iptables está disponível
    if ! command -v iptables &> /dev/null; then
        log_error "iptables não encontrado. Instale com: apt-get install iptables"
        return 1
    fi

    # Função para verificar se regra já existe (idempotência)
    rule_exists() {
        iptables -C "$@" 2>/dev/null
    }

    for i in "${!RATHENA_PORTS[@]}"; do
        local port="${RATHENA_PORTS[$i]}"
        local name="${RATHENA_NAMES[$i]}"

        # Rate limiting: máximo 10 novas conexões/segundo por IP com burst de 15
        # Req 14.1: 10 novas conexões por segundo por IP de origem
        if ! rule_exists INPUT -p tcp --dport "${port}" -m state --state NEW \
            -m hashlimit --hashlimit-above 10/sec --hashlimit-burst 15 \
            --hashlimit-mode srcip --hashlimit-name "${name}" -j DROP; then

            iptables -A INPUT -p tcp --dport "${port}" -m state --state NEW \
                -m hashlimit --hashlimit-above 10/sec --hashlimit-burst 15 \
                --hashlimit-mode srcip --hashlimit-name "${name}" -j DROP
            log_ok "Rate limiting (10/sec, burst 15) configurado na porta ${port} (${name})."
        else
            log_ok "Rate limiting na porta ${port} já configurado. Pulando."
        fi

        # Limite de conexões simultâneas: 20 por IP por porta
        # Req 14.2: máximo 20 conexões simultâneas por IP
        if ! rule_exists INPUT -p tcp --dport "${port}" -m connlimit \
            --connlimit-above 20 --connlimit-mask 32 -j DROP; then

            iptables -A INPUT -p tcp --dport "${port}" -m connlimit \
                --connlimit-above 20 --connlimit-mask 32 -j DROP
            log_ok "Connection limit (20/IP) configurado na porta ${port}."
        else
            log_ok "Connection limit na porta ${port} já configurado. Pulando."
        fi
    done

    # Persistir regras iptables
    persist_iptables_rules
}

# -----------------------------------------------------------------------------
# 4.1 Persistência de regras iptables
# Garante que as regras sobrevivem a reinicializações
# -----------------------------------------------------------------------------
persist_iptables_rules() {
    log_info "Persistindo regras iptables..."

    # Instalar iptables-persistent se não estiver disponível
    if ! command -v netfilter-persistent &> /dev/null; then
        log_info "Instalando iptables-persistent..."
        DEBIAN_FRONTEND=noninteractive apt-get install -y iptables-persistent > /dev/null 2>&1 || {
            # Fallback: salvar manualmente
            mkdir -p /etc/iptables
            iptables-save > /etc/iptables/rules.v4
            log_ok "Regras iptables salvas em /etc/iptables/rules.v4 (fallback)."
            return 0
        }
    fi

    netfilter-persistent save > /dev/null 2>&1
    log_ok "Regras iptables persistidas via netfilter-persistent."
}

# -----------------------------------------------------------------------------
# 5. Configuração conntrack — timeouts reduzidos
# Req 14.4: conntrack com timeout reduzido para mitigação SYN flood
# -----------------------------------------------------------------------------
configure_conntrack() {
    log_info "Configurando conntrack com timeouts reduzidos..."

    # Garantir que o módulo nf_conntrack está carregado
    if ! lsmod | grep -q nf_conntrack; then
        modprobe nf_conntrack 2>/dev/null || {
            log_warn "Não foi possível carregar módulo nf_conntrack. Conntrack runtime config pulado."
            return 0
        }
    fi

    # Aplicar timeouts reduzidos em runtime (complementa sysctl persistido)
    local -A conntrack_params=(
        ["net.netfilter.nf_conntrack_tcp_timeout_syn_recv"]="30"
        ["net.netfilter.nf_conntrack_tcp_timeout_syn_sent"]="30"
        ["net.netfilter.nf_conntrack_tcp_timeout_time_wait"]="30"
        ["net.netfilter.nf_conntrack_max"]="131072"
    )

    local applied=0
    for param in "${!conntrack_params[@]}"; do
        local value="${conntrack_params[${param}]}"
        if sysctl -w "${param}=${value}" > /dev/null 2>&1; then
            ((applied++))
        fi
    done

    if [[ ${applied} -gt 0 ]]; then
        log_ok "Conntrack configurado: ${applied} parâmetros aplicados (timeouts reduzidos para 30s, max 131072)."
    else
        log_warn "Parâmetros conntrack não puderam ser aplicados (pode requerer módulo nf_conntrack carregado)."
    fi
}

# -----------------------------------------------------------------------------
# 6. Remoção de pacotes desnecessários
# Req 8.8: remove pacotes desnecessários
# -----------------------------------------------------------------------------
remove_unnecessary_packages() {
    log_info "Removendo pacotes desnecessários..."

    local unnecessary_packages=(
        telnet
        rsh-client
        rsh-server
        talk
        talkd
        xinetd
        tftp
        tftpd
        nis
        yp-tools
    )

    local removed_count=0
    for pkg in "${unnecessary_packages[@]}"; do
        if dpkg -l "${pkg}" 2>/dev/null | grep -q "^ii"; then
            apt-get remove -y --purge "${pkg}" > /dev/null 2>&1
            ((removed_count++))
        fi
    done

    if [[ ${removed_count} -gt 0 ]]; then
        apt-get autoremove -y > /dev/null 2>&1
        log_ok "${removed_count} pacote(s) desnecessário(s) removido(s)."
    else
        log_ok "Nenhum pacote desnecessário encontrado."
    fi
}

# -----------------------------------------------------------------------------
# 7. Configuração de limites de arquivo
# Req 8.8: configurar limites de arquivo
# -----------------------------------------------------------------------------
configure_file_limits() {
    log_info "Configurando limites de arquivo..."

    local limits_conf="/etc/security/limits.d/99-rathena.conf"

    cat > "${limits_conf}" <<'EOF'
# =============================================================================
# Limites de arquivo para rAthena Server
# Gerado por hardening.sh - NÃO editar manualmente
# =============================================================================

# Limites de file descriptors (soft/hard)
* soft nofile 65535
* hard nofile 65535

# Limites para o usuário root
root soft nofile 65535
root hard nofile 65535

# Limites de processos
* soft nproc 4096
* hard nproc 4096
EOF

    log_ok "Limites de arquivo configurados em ${limits_conf}."

    # Garantir que pam_limits está habilitado
    if [[ -f /etc/pam.d/common-session ]]; then
        if ! grep -q "pam_limits.so" /etc/pam.d/common-session; then
            echo "session required pam_limits.so" >> /etc/pam.d/common-session
            log_ok "pam_limits.so adicionado ao common-session."
        fi
    fi
}

# -----------------------------------------------------------------------------
# Execução principal
# -----------------------------------------------------------------------------
main() {
    local start_time
    start_time=$(date +%s)

    echo "========================================"
    echo " rAthena Server - Hardening"
    echo " Target: Ubuntu 24.04 LTS"
    echo "========================================"
    echo ""

    configure_sysctl
    configure_ssh
    protect_docker_socket
    configure_iptables
    configure_conntrack
    remove_unnecessary_packages
    configure_file_limits

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    echo ""
    echo "========================================"
    echo " Hardening concluído com sucesso!"
    echo " Duração: ${duration}s"
    echo "========================================"
    echo ""
    echo " Configurações aplicadas:"
    echo "  - sysctl: SYN cookies, rp_filter, IPv6 desabilitado"
    echo "  - Conntrack: timeouts reduzidos (30s), max 131072"
    echo "  - SSH: PasswordAuthentication no, PermitRootLogin no"
    echo "  - Docker socket: chmod 660, root:docker"
    echo "  - iptables: rate limit 10/sec (burst 15) + connlimit 20/IP"
    echo "    nas portas 6900, 6121, 5121 (DROP sem resposta)"
    echo "  - Pacotes desnecessários removidos"
    echo "  - Limites de arquivo: nofile 65535, nproc 4096"
    echo ""
    echo " Log completo: ${LOG_FILE}"
    echo ""
    echo " IMPORTANTE: Verifique que você tem acesso SSH"
    echo " via chave pública antes de desconectar!"
    echo ""

    log_ok "Hardening concluído em ${duration}s. Todas as configurações aplicadas."
}

main "$@"
