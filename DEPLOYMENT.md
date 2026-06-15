# Deployment — rAthena Server Infrastructure

## Pré-requisitos

### Hardware Mínimo

| Recurso | Mínimo | Recomendado |
|---------|--------|-------------|
| CPU | 2 vCPUs | 4 vCPUs |
| RAM | 4 GB | 8 GB |
| Disco | 40 GB SSD | 80 GB SSD |
| Rede | 100 Mbps | 1 Gbps |

### Software

- Ubuntu 24.04 LTS (fresh install recomendado)
- Acesso root ou usuário com sudo
- Conexão à internet para download de imagens e pacotes
- Git instalado (`apt install git`)

### Rede

Portas que devem estar abertas no provedor/datacenter:

| Porta | Protocolo | Serviço |
|-------|-----------|---------|
| 22 | TCP | SSH (ou porta customizada) |
| 6900 | TCP | Login Server |
| 6121 | TCP | Char Server |
| 5121 | TCP | Map Server |
| 80 | TCP | FluxCP |
| 443 | TCP | Zabbix Web |
| 3000 | TCP | Grafana |

## Deploy Inicial (Passo a Passo)

### 1. Preparar o servidor

```bash
# Conectar via SSH
ssh root@seu-servidor

# Atualizar sistema
apt update && apt upgrade -y

# Instalar git
apt install -y git
```

### 2. Clonar o repositório

```bash
cd /opt
git clone https://github.com/m1crocorp/T3edSRO.git
cd T3edSRO
```

### 3. Executar provisionamento

O script `setup.sh` instala e configura tudo automaticamente:

```bash
sudo bash scripts/setup.sh
```

O script realiza:
- Instalação do Docker Engine e Docker Compose Plugin
- Configuração do UFW (firewall) com política default deny
- Instalação e configuração do Fail2ban para SSH
- Configuração de unattended-upgrades (patches automáticos)
- Configuração de logrotate para logs do rAthena
- Criação de diretórios de dados (`/opt/rathena/logs/`)
- Geração de senhas fortes (se não definidas no .env)

Se o Docker já estiver instalado, o script pula a instalação e prossegue com a configuração restante.

### 4. Configurar variáveis de ambiente

```bash
cp .env.example .env
nano .env
```

**Variáveis obrigatórias a revisar:**

```env
# MariaDB
MARIADB_ROOT_PASSWORD=<gerada automaticamente ou defina>
RATHENA_DB_PASSWORD=<gerada automaticamente ou defina>

# rAthena
PACKETVER=20211103          # Deve corresponder ao seu cliente RO
INTER_SERVER_PASSWORD=<gerada automaticamente ou defina>
SERVER_NAME=MeuServidor

# Grafana
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=<defina senha forte>

# Zabbix
ZABBIX_ADMIN_PASSWORD=<defina senha forte>

# Alertas
ALERT_WEBHOOK_URL=<URL do webhook Discord/Telegram/Slack>
```

### 5. Executar hardening de segurança

```bash
sudo bash scripts/hardening.sh
```

Configura: sysctl, SSH hardening, Docker socket protection, rate limiting iptables.

### 6. Subir todos os serviços

```bash
docker compose up -d
```

Na primeira execução, isso irá:
1. Compilar o rAthena a partir do código-fonte (pode levar 5-15 minutos)
2. Inicializar o banco de dados MariaDB com schema do rAthena
3. Criar todos os usuários e permissões
4. Iniciar todos os serviços na ordem correta

### 7. Verificar status

```bash
# Verificar se todos estão healthy
docker compose ps

# Saída esperada (após ~3 minutos):
# mariadb         healthy
# login-server    healthy
# char-server     healthy
# map-server      healthy
# zabbix-server   healthy
# zabbix-web      healthy
# zabbix-agent2   running
# grafana         healthy
# fluxcp          healthy
# backup          running
# autoheal        running
```

### 8. Verificar logs

```bash
# Login Server
docker compose logs login-server --tail 20

# Procurar por: "[Status]: The login-server is ready"
# Char Server
docker compose logs char-server --tail 20

# Procurar por: "[Status]: The char-server is ready"
# Map Server
docker compose logs map-server --tail 20

# Procurar por: "[Status]: The map-server is ready"
```

### 9. Primeiro acesso

#### FluxCP (Painel Web)
- Acesse: `http://<IP-do-servidor>/`
- Registre uma conta de jogador

#### Grafana (Monitoramento)
- Acesse: `http://<IP-do-servidor>:3000`
- Login com credenciais definidas no `.env`

#### Zabbix Web (Alertas)
- Acesse: `https://<IP-do-servidor>:443`
- Login: `Admin` / senha definida no `.env`

#### Cliente Ragnarok Online
- Configure o cliente com:
  - IP: `<IP-do-servidor>`
  - Porta: `6900`
  - PACKETVER: deve corresponder ao valor configurado
- Faça login com a conta criada no FluxCP

## Deploy de Atualizações

### Via CI/CD (recomendado)

1. Faça alterações no código e abra um PR
2. CI valida automaticamente (lint, build test, trivy)
3. Após merge, CI faz build e push das imagens para GHCR
4. Acione `deploy.yml` manualmente no GitHub Actions

### Deploy manual

```bash
# No servidor
cd /opt/rathena-infra

# Pull código atualizado
git pull origin main

# Rebuild das imagens (se Dockerfile mudou)
docker compose build

# Ou pull de imagens pré-construídas (se usando GHCR)
docker compose pull

# Recreate dos containers afetados
docker compose up -d
```

### Deploy com zero downtime (parcial)

Para minimizar impacto nos jogadores:

```bash
# 1. Backup primeiro
docker compose exec backup /scripts/backup.sh

# 2. Atualizar serviços que não afetam gameplay primeiro
docker compose up -d grafana zabbix-web fluxcp

# 3. Atualizar servidores rAthena (causa reconexão dos jogadores)
docker compose up -d login-server char-server map-server
```

## Rollback

### Via CI/CD

Acione o workflow `rollback.yml` no GitHub Actions, que reverte para a tag anterior das imagens.

### Rollback manual

```bash
# Identificar versão anterior
docker compose images  # Ver tags atuais
git log --oneline -5   # Ver commits recentes

# Reverter para commit anterior
git checkout <commit-anterior>
docker compose up -d

# Ou se usando GHCR, alterar tags no .env/compose e:
docker compose pull
docker compose up -d
```

## Verificação Pós-Deploy

Checklist após qualquer deploy:

- [ ] `docker compose ps` — todos os serviços healthy
- [ ] `docker compose logs login-server --tail 5` — sem erros
- [ ] `docker compose logs char-server --tail 5` — sem erros
- [ ] `docker compose logs map-server --tail 5` — sem erros
- [ ] Testar login de jogador no cliente RO
- [ ] Verificar Grafana — dashboards com dados atuais
- [ ] Verificar que alertas Zabbix não estão disparando

## Troubleshooting de Deploy

### Serviço não inicia (stays "starting")

```bash
# Verificar logs detalhados
docker compose logs <serviço> --tail 50

# Causas comuns:
# - MariaDB não healthy → dependência não satisfeita
# - Senha incorreta no .env
# - PACKETVER incompatível com código
# - Porta já em uso no host
```

### Build falha

```bash
# Verificar se tem espaço em disco
df -h

# Limpar cache Docker se necessário
docker builder prune -f

# Rebuild sem cache
docker compose build --no-cache
```

### MariaDB não inicializa

```bash
# Verificar logs
docker compose logs mariadb --tail 50

# Causas comuns:
# - innodb_buffer_pool_size muito grande para RAM disponível
# - Volume corrompido (precisa restaurar backup)
# - Permissões incorretas no volume
```

### Healthcheck falha repetidamente

```bash
# Verificar healthcheck manualmente
docker compose exec login-server pidof login-server

# Se o binário não responde:
docker compose exec login-server ls -la /rathena/
docker compose exec login-server cat /rathena/conf/import/login_athena.conf
```
