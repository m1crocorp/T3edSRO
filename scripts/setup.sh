#!/bin/bash
# ============================================================
# rAthena Server Infrastructure - Provisioning Script (setup.sh)
# ============================================================
# Este script provisiona um servidor Ubuntu 24.04 LTS com todos
# os componentes necessários para rodar a infraestrutura rAthena.
#
# Componentes instalados/configurados:
#   - Docker Engine + Docker Compose Plugin (via repo oficial)
#   - UFW (firewall) com política default DROP (INPUT e FORWARD)
#   - fail2ban (proteção brute-force SSH)
#   - unattended-upgrades (patches de segurança automáticos)
#   - logrotate (rotação de logs do rAthena)
#   - Diretórios de dados e logs
#   - Geração de senhas fortes (se necessário)
#
# Uso: sudo bash scripts/setup.sh
#
# O script é IDEMPOTENTE — pode ser re-executado com segurança.
# ============================================================

set -euo pipefail

# ------------------------------------------------------------
# Configuração de logging
# ------------------------------------------------------------
LOG_FILE="/var/log/rathena-setup.log"

# Garantir que o diretório de log existe
mkdir -p "$(dirname "$LOG_FILE")"

# Função de logging dual (stdout + arquivo)
_log() {
    local level="$1"
    shift
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local message="[${timestamp}] [${level}] $*"
    echo "$message" >> "$LOG_FILE"
}

# ------------------------------------------------------------
# Cores e formatação para output
# ------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
    _log "INFO" "$1"
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $1"
    _log "OK" "$1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    _log "WARN" "$1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    _log "ERROR" "$1"
}

# ------------------------------------------------------------
# Verificações iniciais
# ------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Este script deve ser executado como root ou com sudo."
        echo "Uso: sudo bash $0"
        exit 1
    fi
}

check_ubuntu() {
    if [[ ! -f /etc/os-release ]]; then
        log_error "Não foi possível detectar o sistema operacional."
        exit 1
    fi

    # shellcheck source=/dev/null
    source /etc/os-release

    if [[ "${ID}" != "ubuntu" ]]; then
        log_warn "Este script foi projetado para Ubuntu. Detectado: ${ID}"
        log_warn "A execução pode falhar em outros sistemas."
    fi

    if [[ "${VERSION_ID}" != "24.04" ]]; then
        log_warn "Versão recomendada: Ubuntu 24.04 LTS. Detectada: ${VERSION_ID}"
    fi
}

# ------------------------------------------------------------
# Instalação do Docker Engine + Docker Compose Plugin
# ------------------------------------------------------------
install_docker() {
    # Detectar se Docker já está instalado e funcional (idempotência)
    if command -v docker &>/dev/null && docker info &>/dev/null; then
        log_success "Docker já está instalado e funcional. Pulando instalação."
        docker --version | tee -a "$LOG_FILE"
        return 0
    fi

    log_info "Instalando Docker Engine via repositório oficial..."

    # Remover pacotes antigos/conflitantes
    local old_packages=(
        docker.io docker-doc docker-compose docker-compose-v2
        podman-docker containerd runc
    )
    for pkg in "${old_packages[@]}"; do
        apt-get remove -y "$pkg" 2>/dev/null || true
    done

    # Instalar dependências para adicionar repositório
    apt-get update
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        gnupg \
        lsb-release

    # Adicionar chave GPG oficial do Docker
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
        gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    # Adicionar repositório oficial do Docker
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu \
        $(lsb_release -cs) stable" | \
        tee /etc/apt/sources.list.d/docker.list > /dev/null

    # Instalar Docker Engine e Docker Compose Plugin
    apt-get update
    apt-get install -y --no-install-recommends \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    # Habilitar e iniciar Docker
    systemctl enable docker
    systemctl start docker

    # Verificar instalação
    if docker info &>/dev/null; then
        log_success "Docker instalado com sucesso."
        docker --version | tee -a "$LOG_FILE"
        docker compose version | tee -a "$LOG_FILE"
    else
        log_error "Falha na instalação do Docker."
        exit 1
    fi
}

# ------------------------------------------------------------
# Configuração do UFW (Firewall)
# ------------------------------------------------------------
configure_ufw() {
    log_info "Configurando UFW (firewall)..."

    # Instalar UFW se não presente
    apt-get install -y --no-install-recommends ufw

    # Políticas padrão: DROP para INPUT e FORWARD, permitir saída
    ufw default deny incoming
    ufw default deny routed
    ufw default allow outgoing

    # Detectar porta SSH do .env ou usar padrão
    local ssh_port="${SSH_PORT:-22}"

    # Permitir portas necessárias
    ufw allow "${ssh_port}/tcp" comment "SSH"
    ufw allow 6900/tcp comment "rAthena Login Server"
    ufw allow 6121/tcp comment "rAthena Char Server"
    ufw allow 5121/tcp comment "rAthena Map Server"
    ufw allow 3000/tcp comment "Grafana"
    ufw allow 443/tcp comment "Zabbix Web (HTTPS)"
    ufw allow 80/tcp comment "FluxCP (HTTP)"

    # Habilitar UFW (não-interativo)
    echo "y" | ufw enable

    # Recarregar regras
    ufw reload

    log_success "UFW configurado com política default DROP (INPUT e FORWARD)."
    ufw status verbose | tee -a "$LOG_FILE"
}

# ------------------------------------------------------------
# Configuração do fail2ban
# ------------------------------------------------------------
configure_fail2ban() {
    log_info "Configurando fail2ban..."

    # Instalar fail2ban
    apt-get install -y --no-install-recommends fail2ban

    # Detectar porta SSH configurada
    local ssh_port="${SSH_PORT:-22}"

    # Criar configuração local para SSH
    cat > /etc/fail2ban/jail.local << EOF
# ============================================================
# fail2ban - Configuração para rAthena Server
# ============================================================

[DEFAULT]
# Ignorar localhost
ignoreip = 127.0.0.1/8 ::1

# Ação padrão: banir via UFW
banaction = ufw

[sshd]
enabled = true
port = ${ssh_port}
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
findtime = 60
bantime = 600
EOF

    # Habilitar e reiniciar fail2ban
    systemctl enable fail2ban
    systemctl restart fail2ban

    log_success "fail2ban configurado: maxretry=5, findtime=60s, bantime=600s (porta SSH: ${ssh_port})."
}

# ------------------------------------------------------------
# Configuração do unattended-upgrades
# ------------------------------------------------------------
configure_unattended_upgrades() {
    log_info "Configurando unattended-upgrades (patches automáticos)..."

    # Instalar unattended-upgrades
    apt-get install -y --no-install-recommends unattended-upgrades apt-listchanges

    # Configurar para aplicar apenas patches de segurança
    cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
// Apenas patches de segurança do Ubuntu
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

// Não atualizar automaticamente pacotes que podem causar reinicialização
Unattended-Upgrade::Package-Blacklist {
};

// Reiniciar automaticamente se necessário (fora do horário de pico)
Unattended-Upgrade::Automatic-Reboot "false";

// Remover dependências não utilizadas após upgrade
Unattended-Upgrade::Remove-Unused-Dependencies "true";

// Remover kernels antigos não utilizados
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";

// Logging
Unattended-Upgrade::SyslogEnable "true";
EOF

    # Habilitar atualizações automáticas
    cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
EOF

    # Habilitar o timer
    systemctl enable unattended-upgrades
    systemctl restart unattended-upgrades

    log_success "unattended-upgrades configurado (apenas patches de segurança)."
}

# ------------------------------------------------------------
# Configuração do logrotate para logs do rAthena
# ------------------------------------------------------------
configure_logrotate() {
    log_info "Configurando logrotate para logs do rAthena..."

    cat > /etc/logrotate.d/rathena << 'EOF'
/opt/rathena/logs/login/*.log
/opt/rathena/logs/char/*.log
/opt/rathena/logs/map/*.log
{
    daily
    rotate 7
    compress
    compresscmd /usr/bin/gzip
    compressext .gz
    missingok
    notifempty
    create 0644 1000 1000
    dateext
    dateformat -%Y%m%d
    sharedscripts
    postrotate
        # Sinalizar containers para reabrir logs (se necessário)
        /usr/bin/docker kill --signal=USR1 $(docker ps -qf "name=login-server") 2>/dev/null || true
        /usr/bin/docker kill --signal=USR1 $(docker ps -qf "name=char-server") 2>/dev/null || true
        /usr/bin/docker kill --signal=USR1 $(docker ps -qf "name=map-server") 2>/dev/null || true
    endscript
}
EOF

    log_success "logrotate configurado: rotação diária, retenção 7 dias, compressão gzip."
}

# ------------------------------------------------------------
# Criação de diretórios de dados
# ------------------------------------------------------------
create_directories() {
    log_info "Criando diretórios de dados e logs..."

    # Diretórios de logs do rAthena (montados nos containers)
    mkdir -p /opt/rathena/logs/login
    mkdir -p /opt/rathena/logs/char
    mkdir -p /opt/rathena/logs/map

    # Permissões para o usuário rathena (UID 1000, GID 1000)
    chown -R 1000:1000 /opt/rathena/logs/

    log_success "Diretórios criados em /opt/rathena/logs/ (owner: 1000:1000)."
}

# ------------------------------------------------------------
# Geração e validação de senhas
# ------------------------------------------------------------
generate_password() {
    # Gera senha de 32 caracteres alfanuméricos + especiais via openssl rand
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c 32
}

validate_password() {
    local pass="$1"
    local var_name="${2:-}"

    if [[ ${#pass} -lt 16 ]]; then
        log_warn "Senha fraca detectada para ${var_name} (< 16 caracteres). Recomenda-se trocar."
        return 0  # Permite inicialização com aviso
    fi

    if ! echo "$pass" | grep -qP '[!@#$%^&*]'; then
        log_warn "Senha sem caracteres especiais para ${var_name}. Recomenda-se incluir !@#\$%^&*"
    fi

    return 0
}

setup_credentials() {
    log_info "Verificando credenciais no arquivo .env..."

    # Detectar diretório do projeto (onde o script está)
    local project_dir
    project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    local env_file="${project_dir}/.env"

    # Se .env não existe, criar a partir do .env.example
    if [[ ! -f "$env_file" ]]; then
        if [[ -f "${project_dir}/.env.example" ]]; then
            cp "${project_dir}/.env.example" "$env_file"
            log_info "Arquivo .env criado a partir de .env.example"
        else
            log_error "Arquivo .env.example não encontrado em ${project_dir}"
            return 1
        fi
    fi

    # Lista de variáveis de credenciais que devem ter senhas fortes
    local credential_vars=(
        "MARIADB_ROOT_PASSWORD"
        "RATHENA_DB_PASSWORD"
        "INTER_SERVER_PASSWORD"
        "ZBX_DB_PASSWORD"
        "GF_SECURITY_ADMIN_PASSWORD"
        "FLUXCP_DB_PASSWORD"
        "BACKUP_DB_PASSWORD"
    )

    local generated_any=0

    for var in "${credential_vars[@]}"; do
        # Ler valor atual da variável no .env
        local current_value
        current_value=$(grep -E "^${var}=" "$env_file" 2>/dev/null | cut -d'=' -f2- | tr -d '"' | tr -d "'")

        # Verificar se é um placeholder ou está vazio
        if [[ -z "$current_value" ]] || \
           [[ "$current_value" == change_me* ]] || \
           [[ "$current_value" == "CHANGE_ME"* ]] || \
           [[ "$current_value" == "your_"* ]] || \
           [[ "$current_value" == "example"* ]]; then

            # Gerar nova senha forte
            local new_pass
            new_pass=$(generate_password)

            # Substituir no .env
            if grep -q "^${var}=" "$env_file"; then
                sed -i "s|^${var}=.*|${var}=${new_pass}|" "$env_file"
            else
                echo "${var}=${new_pass}" >> "$env_file"
            fi

            log_info "Senha gerada automaticamente para ${var} (32 chars)"
            generated_any=1
        else
            # Validar senha existente (apenas aviso, não bloqueia)
            validate_password "$current_value" "$var"
        fi
    done

    if [[ $generated_any -eq 1 ]]; then
        log_success "Senhas fortes geradas (32 chars alfanuméricos + especiais). Confira o arquivo .env"
    else
        log_success "Todas as credenciais já estão definidas no .env"
    fi

    # Proteger arquivo .env
    chmod 600 "$env_file"
}

# ------------------------------------------------------------
# Instalação de dependências auxiliares
# ------------------------------------------------------------
install_dependencies() {
    log_info "Instalando dependências auxiliares..."

    apt-get update
    apt-get install -y --no-install-recommends \
        openssl \
        curl \
        wget \
        jq \
        htop \
        logrotate

    log_success "Dependências auxiliares instaladas."
}

# ------------------------------------------------------------
# Execução principal
# ------------------------------------------------------------
main() {
    echo "============================================================"
    echo " rAthena Server - Script de Provisionamento"
    echo " Ubuntu 24.04 LTS"
    echo "============================================================"
    echo ""

    # Iniciar log
    _log "INFO" "========== Início do provisionamento =========="

    check_root
    check_ubuntu

    log_info "Iniciando provisionamento do servidor..."
    echo ""

    # 1. Dependências auxiliares
    install_dependencies
    echo ""

    # 2. Docker Engine + Docker Compose Plugin
    install_docker
    echo ""

    # 3. Firewall (UFW) — default DROP (INPUT e FORWARD)
    configure_ufw
    echo ""

    # 4. Proteção brute-force (fail2ban)
    configure_fail2ban
    echo ""

    # 5. Patches automáticos de segurança
    configure_unattended_upgrades
    echo ""

    # 6. Logrotate para rAthena
    configure_logrotate
    echo ""

    # 7. Diretórios de dados
    create_directories
    echo ""

    # 8. Geração/validação de credenciais
    setup_credentials
    echo ""

    # Resumo final
    echo "============================================================"
    log_success "Provisionamento concluído com sucesso!"
    echo ""
    echo "Próximos passos:"
    echo "  1. Revise o arquivo .env com as credenciais geradas"
    echo "  2. Ajuste SERVER_PUBLIC_IP com o IP público do servidor"
    echo "  3. Execute: docker compose up -d"
    echo "  4. Verifique: docker compose ps"
    echo ""
    echo "Para hardening adicional, execute:"
    echo "  sudo bash scripts/hardening.sh"
    echo "============================================================"

    _log "INFO" "========== Provisionamento finalizado com sucesso =========="
}

# Executar
main "$@"
