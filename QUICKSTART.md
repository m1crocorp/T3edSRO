# QUICKSTART — rAthena Server Infrastructure

> **Tipo:** Procedimento  
> **Ambiente:** Ubuntu 24.04 LTS · Docker Compose v2 · rAthena  
> **Audiência:** Administradores de servidor  
> **Última revisão:** Junho 2026  
> **Status:** Validado

---

## Problema / Objetivo

Provisionar e iniciar um servidor rAthena de produção em uma máquina Ubuntu 24.04 LTS nova, incluindo banco de dados, monitoramento, painel web e backup automatizado — pronto para receber jogadores.

---

## Pré-requisitos

| Recurso | Mínimo | Recomendado |
|---------|--------|-------------|
| CPU | 2 vCPUs | 4 vCPUs |
| RAM | 4 GB | 8 GB |
| Disco | 40 GB SSD | 80 GB NVMe |
| SO | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS |
| Acesso | root ou sudo | — |
| Rede | IP público dedicado | IP com proteção DDoS L4 |

**Portas que devem estar liberadas no provedor/painel de VPS:**

| Porta | Serviço |
|-------|---------|
| 22 | SSH |
| 5121 | Map Server |
| 6121 | Char Server |
| 6900 | Login Server |
| 80 | FluxCP (painel web) |
| 443 | Zabbix Web (HTTPS) |
| 3000 | Grafana (dashboards) |

**Você precisará de:**
- Cliente RO compatível com o PACKETVER que vai configurar (padrão: `20211103`)
- Terminal SSH para acessar o servidor

---

## Resolução (Passo a Passo)

### 1. Clonar o repositório

```bash
git clone https://github.com/seu-org/rathena-infra.git
cd rathena-infra
```

### 2. Executar provisionamento do host

O script instala Docker, configura firewall (UFW), fail2ban, unattended-upgrades, logrotate e gera senhas fortes automaticamente.

```bash
sudo bash scripts/setup.sh
```

> O script é idempotente — pode ser re-executado sem problemas.

### 3. Configurar variáveis de ambiente

```bash
cp .env.example .env
nano .env
```

**Variáveis obrigatórias a ajustar:**

| Variável | O que configurar |
|----------|-----------------|
| `SERVER_PUBLIC_IP` | IP público real do seu servidor |
| `SERVER_NAME` | Nome exibido na lista de servidores do cliente |
| `PACKETVER` | Versão do protocolo do cliente RO (ex: `20211103`) |

> As senhas (`MARIADB_ROOT_PASSWORD`, `RATHENA_DB_PASSWORD`, `INTER_SERVER_PASSWORD`, etc.) são geradas automaticamente pelo `setup.sh` se estiverem com valor placeholder. Verifique o `.env` após executar o script.

### 4. Subir todos os serviços

```bash
docker compose up -d
```

> **Tempo esperado:** 5–10 minutos na primeira execução (compilação do rAthena). Builds seguintes usam cache.

### 5. Verificar que tudo está saudável

```bash
docker compose ps
```

**Resultado esperado:** Todos os serviços com status `healthy` ou `running`.

Se algum serviço estiver `starting`, aguarde até 3 minutos (start_period do healthcheck).

### 6. Validar conectividade dos servidores de jogo

```bash
nc -z localhost 6900 && echo "Login Server: OK" || echo "Login Server: FALHA"
nc -z localhost 6121 && echo "Char Server: OK"  || echo "Char Server: FALHA"
nc -z localhost 5121 && echo "Map Server: OK"   || echo "Map Server: FALHA"
```

### 7. Criar conta de jogador e testar login

1. Acesse o FluxCP: `http://<IP-DO-SERVIDOR>/`
2. Registre uma conta de teste
3. Configure o cliente RO:
   - **IP:** `<IP-DO-SERVIDOR>`
   - **PACKETVER:** mesmo valor do `.env`
4. Abra o cliente e faça login

---

## Causa Raiz

Não se aplica (procedimento de instalação, não resolução de incidente).

---

## Verificação

| Checagem | Comando | Resultado Esperado |
|----------|---------|-------------------|
| Serviços rodando | `docker compose ps` | Todos `healthy` |
| Login Server TCP | `nc -z localhost 6900` | Exit code 0 |
| Char Server TCP | `nc -z localhost 6121` | Exit code 0 |
| Map Server TCP | `nc -z localhost 5121` | Exit code 0 |
| FluxCP acessível | `curl -s -o /dev/null -w "%{http_code}" http://localhost:80` | `200` |
| Grafana acessível | `curl -s -o /dev/null -w "%{http_code}" http://localhost:3000` | `200` ou `302` |
| Backup programado | `docker compose exec backup crontab -l` | Cron job às 04:00 UTC |
| Firewall ativo | `sudo ufw status` | `Status: active` com portas listadas |

---

## Troubleshooting

| Sintoma | Causa Provável | Ação |
|---------|---------------|------|
| Serviço `unhealthy` | Dependência ainda iniciando | Aguardar 3 min; verificar logs: `docker compose logs <serviço>` |
| Erro conexão DB nos logs | MariaDB ainda inicializando | Aguardar MariaDB ficar `healthy`: `docker compose ps mariadb` |
| Cliente não conecta | Firewall bloqueando | Verificar: `sudo ufw status`; liberar portas se necessário |
| "Packet version mismatch" | PACKETVER inconsistente | Ajustar `PACKETVER` no `.env` para corresponder ao cliente; rebuild: `docker compose build` |
| FluxCP mostra página de manutenção | MariaDB indisponível | Aguardar DB ou verificar: `docker compose logs mariadb` |
| Login rejeita senha correta | Conta bloqueada ou MD5 mismatch | Verificar `LOGIN_USE_MD5` no `.env` vs configuração do cliente |
| Build demora >15 min | Rede lenta para git clone | Verificar conectividade; considerar usar `RATHENA_BRANCH` com commit específico |
| `Permission denied` no setup.sh | Falta sudo | Executar com: `sudo bash scripts/setup.sh` |

---

## Próximos Passos (Pós-Deploy)

| Ação | Comando / Referência |
|------|---------------------|
| Executar hardening de segurança | `sudo bash scripts/hardening.sh` |
| Configurar proteção DDoS L4 | Ver seção DDoS no [README.md](README.md) |
| Importar template Zabbix | Zabbix Web → Configuration → Templates → Import: `monitoring/zabbix/templates/rathena-monitoring.xml` |
| Configurar webhook de alertas | Editar `{$ALERT.WEBHOOK.URL}` no template Zabbix |
| Adicionar NPCs customizados | Colocar scripts em `npc/custom/`; reiniciar: `docker compose restart map-server` |
| Testar restauração de backup | `sudo bash scripts/restore.sh /backups/<arquivo>.sql.gz` |
| Configurar CI/CD | Adicionar secrets no GitHub: `SSH_PRIVATE_KEY`, `SERVER_HOST`, `SERVER_USER`, `GHCR_TOKEN` |

---

## Documentação Relacionada

| Documento | Conteúdo |
|-----------|----------|
| [README.md](README.md) | Visão geral, arquitetura, comandos úteis |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | Procedimentos operacionais e tabela de decisão |
| [BACKUP_DR.md](BACKUP_DR.md) | Backup, restauração, PITR, RPO/RTO |
| [SECURITY.md](SECURITY.md) | Hardening, firewall, rate limiting |
| [MONITORING.md](MONITORING.md) | Zabbix, Grafana, alertas |
| [CICD.md](CICD.md) | Pipelines GitHub Actions |

---

## Metadados KCS

| Campo | Valor |
|-------|-------|
| **ID do Artigo** | QS-001 |
| **Título** | Quickstart — Deploy completo rAthena Server |
| **Estado** | Publicado |
| **Confiança** | Validado (testado em ambiente limpo) |
| **Criado em** | Junho 2026 |
| **Última revisão** | Junho 2026 |
| **Proprietário** | Equipe de Infraestrutura |
| **Palavras-chave** | rathena, deploy, docker, quickstart, primeiro-uso, instalação, ubuntu |
| **Aplicabilidade** | Ubuntu 24.04 LTS, Docker Compose v2, rAthena master |
