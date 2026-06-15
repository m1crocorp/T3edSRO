# Segurança e Hardening — rAthena Server Infrastructure

## Modelo de Ameaças

Servidores de jogos online são alvos frequentes de:

| Ameaça | Vetor | Mitigação |
|--------|-------|-----------|
| DDoS volumétrico | Flood TCP/UDP nas portas de jogo | Rate limiting local + proteção DDoS do provedor |
| Brute-force SSH | Tentativas massivas de autenticação | Fail2ban + SSH apenas por chave |
| Exploits rAthena | CVEs conhecidas no emulador | Patches de segurança, atualização periódica |
| Acesso não autorizado | Credenciais fracas ou expostas | Geração automática de senhas fortes (32 chars) |
| Escalação de privilégio | Container escape | Non-root, read-only filesystem, cap_drop ALL |
| SQL Injection | Pacotes malformados ao rAthena | Atualização do emulador, menor privilégio DB |

## Camadas de Segurança

### Camada 1: Rede (Host)

#### UFW Firewall

Política default DROP com portas explicitamente permitidas:

```bash
# Política padrão
ufw default deny incoming
ufw default allow outgoing

# Portas permitidas
ufw allow 22/tcp comment 'SSH'           # ou porta customizada
ufw allow 6900/tcp comment 'Login Server'
ufw allow 6121/tcp comment 'Char Server'
ufw allow 5121/tcp comment 'Map Server'
ufw allow 3000/tcp comment 'Grafana'
ufw allow 443/tcp comment 'Zabbix Web'
ufw allow 80/tcp comment 'FluxCP'

ufw enable
```

#### Fail2ban

Proteção contra brute-force SSH:

```ini
# /etc/fail2ban/jail.local
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 5
findtime = 60
bantime = 600
```

Quando mais de 5 tentativas falham em 60 segundos de um mesmo IP, o IP é bloqueado por 600 segundos (10 minutos).

#### Rate Limiting (iptables)

Proteção contra flood nas portas do rAthena:

```bash
# Limite de novas conexões: 10/segundo por IP, burst 15
iptables -A INPUT -p tcp --dport 6900 -m state --state NEW \
    -m hashlimit --hashlimit-above 10/sec --hashlimit-burst 15 \
    --hashlimit-mode srcip --hashlimit-name rathena_login -j DROP

iptables -A INPUT -p tcp --dport 6121 -m state --state NEW \
    -m hashlimit --hashlimit-above 10/sec --hashlimit-burst 15 \
    --hashlimit-mode srcip --hashlimit-name rathena_char -j DROP

iptables -A INPUT -p tcp --dport 5121 -m state --state NEW \
    -m hashlimit --hashlimit-above 10/sec --hashlimit-burst 15 \
    --hashlimit-mode srcip --hashlimit-name rathena_map -j DROP

# Limite de conexões simultâneas: 20 por IP por porta
iptables -A INPUT -p tcp --dport 6900 -m connlimit --connlimit-above 20 -j DROP
iptables -A INPUT -p tcp --dport 6121 -m connlimit --connlimit-above 20 -j DROP
iptables -A INPUT -p tcp --dport 5121 -m connlimit --connlimit-above 20 -j DROP
```

#### Sysctl (Proteção SYN Flood)

```bash
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv6.conf.all.disable_ipv6 = 1  # Se IPv6 não utilizado
```

### Camada 2: Container

| Controle | Configuração | Propósito |
|----------|-------------|-----------|
| Non-root | `USER rathena` (UID 1000) | Sem privilégios de root |
| Read-only FS | `read_only: true` | Previne escrita maliciosa |
| tmpfs | `/tmp`, `/run`, `/rathena/conf/import` | Áreas de escrita temporária |
| No new privileges | `security_opt: no-new-privileges:true` | Impede escalação |
| Cap drop | `cap_drop: ALL` | Remove todas as capabilities |
| Resource limits | `deploy.resources.limits` | Previne resource exhaustion |
| Network isolation | Rede interna sem acesso externo | MariaDB nunca exposto |

### Camada 3: Aplicação

#### Banco de Dados — Menor Privilégio

| Usuário | Banco | Privilégios |
|---------|-------|-------------|
| `rathena` | ragnarok, ragnarok_log | SELECT, INSERT, UPDATE, DELETE |
| `rathena_backup` | ragnarok, ragnarok_log | SELECT, LOCK TABLES, SHOW VIEW, EVENT, TRIGGER |
| `fluxcp` | ragnarok | SELECT, INSERT, UPDATE, DELETE |
| `zabbix` | zabbix | ALL PRIVILEGES (banco isolado) |

O MariaDB aceita conexões apenas da rede Docker interna — sem port binding no host (porta 3306 nunca exposta externamente).

#### Inter_Server_Password

Senha forte e única gerada automaticamente no primeiro deploy para autenticação entre Login Server, Char Server e Map Server. Configurada em `inter_athena.conf` via entrypoint script.

#### Geração de Senhas

No primeiro deploy, o script `setup.sh` gera senhas de 32 caracteres (alfanuméricos + especiais) para todas as credenciais não definidas no `.env`:

```bash
generate_password() {
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9!@#$%^&*' | head -c 32
}
```

Se credenciais fracas forem fornecidas (< 16 caracteres ou sem especiais), um aviso é registrado no log mas a inicialização é permitida.

### Camada 4: Host OS

| Controle | Configuração |
|----------|-------------|
| SSH | Apenas chaves públicas, `PasswordAuthentication no`, `PermitRootLogin no` |
| Patches automáticos | `unattended-upgrades` para security updates |
| Docker socket | `chmod 660`, ownership `root:docker` |
| Pacotes desnecessários | Removidos pelo `hardening.sh` |

## Scripts de Segurança

### setup.sh

Provisionamento inicial que configura:
- Docker Engine + Compose Plugin
- UFW com regras de firewall
- Fail2ban para SSH
- unattended-upgrades
- Geração de senhas fortes
- Diretórios de dados

### hardening.sh

Hardening adicional que configura:
- Parâmetros sysctl de rede
- SSH hardening
- Docker socket protection
- Rate limiting iptables
- Remoção de pacotes desnecessários
- Desabilitação de IPv6 (se não utilizado)

## Processo de Atualização de Segurança

1. **Monitorar** — Verificar periodicamente [rAthena Security Advisories](https://github.com/rathena/rathena/security/advisories)
2. **Avaliar** — Classificar severidade da CVE e impacto no ambiente
3. **Backup** — Executar backup completo antes de qualquer atualização
4. **Atualizar** — Alterar `RATHENA_BRANCH` ou commit no Dockerfile
5. **Build** — Pipeline CI reconstrói imagens automaticamente
6. **Deploy** — Deploy manual via workflow_dispatch com validação
7. **Verificar** — Confirmar healthchecks e funcionalidade pós-deploy
8. **Rollback** — Se regressão detectada, usar workflow de rollback

## Proteção DDoS Adicional

O rate limiting local protege contra ataques de baixo volume. Para proteção contra ataques volumétricos (Gbps), utilize proteção de rede upstream:

| Provedor | Proteção | Observação |
|----------|----------|-----------|
| OVH Game | Anti-DDoS L4 permanente | Incluída nos servidores Game |
| Hetzner | DDoS Protection | Incluída, até 500 Gbps |
| Path.net | Game DDoS Mitigation | Especializado, túnel GRE |

## Checklist de Segurança (Pós-Deploy)

- [ ] SSH funciona apenas com chave (testar: `ssh -o PasswordAuthentication=yes` deve falhar)
- [ ] UFW ativo com política default deny (`ufw status verbose`)
- [ ] Fail2ban rodando (`fail2ban-client status sshd`)
- [ ] MariaDB não acessível externamente (`nmap -p 3306 <IP>` deve mostrar filtered/closed)
- [ ] Containers rodando como non-root (`docker exec login-server whoami` → "rathena")
- [ ] Docker socket protegido (`ls -la /var/run/docker.sock` → 660 root:docker)
- [ ] Senhas no .env com 32+ caracteres
- [ ] Rate limiting ativo (`iptables -L -n | grep hashlimit`)
- [ ] unattended-upgrades habilitado (`systemctl status unattended-upgrades`)
