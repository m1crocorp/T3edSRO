# CI/CD — rAthena Server Infrastructure

## Visão Geral

O pipeline de CI/CD utiliza GitHub Actions para automatizar validação, build, deploy e rollback da infraestrutura. Imagens Docker são armazenadas no GitHub Container Registry (ghcr.io).

```
PR → validate.yml (lint + build test + trivy scan)
Merge → build.yml (build + push GHCR)
Manual → deploy.yml (backup + SSH + pull + recreate)
Manual → rollback.yml (revert para tag anterior)
```

## Workflows

### 1. validate.yml — Validação em Pull Request

**Trigger**: Pull request criado ou atualizado

| Step | Ferramenta | Propósito |
|------|-----------|-----------|
| Lint Dockerfiles | hadolint | Validar best practices Docker |
| Lint shell scripts | shellcheck | Validar scripts Bash |
| Compose validation | `docker compose config --quiet` | Validar sintaxe YAML |
| Env check | script customizado | Verificar .env.example vs variáveis referenciadas |
| Build test | `docker build` (sem push) | Validar compilação do rAthena |
| Security scan | Trivy | Scan de vulnerabilidades nas imagens |

**Bloqueio de merge**: Se hadolint, shellcheck, build ou Trivy (CRITICAL/HIGH) falham, o PR é marcado como falho.

**Artefatos**: Em caso de falha no build, logs completos são salvos como artefato do workflow.

### 2. build.yml — Build e Push para Registry

**Trigger**: Push na branch `main` (merge de PR)

| Step | Ação |
|------|------|
| Build login-server | `docker build --target login-server` |
| Build char-server | `docker build --target char-server` |
| Build map-server | `docker build --target map-server` |
| Build fluxcp | `docker build -f docker/fluxcp/Dockerfile` |
| Tag | `ghcr.io/m1crocorp/rathena-login:sha-abc1234` (SHA curto) |
| Push | Push para GitHub Container Registry |

**Tagging**: Cada imagem recebe tag com SHA curto do commit (`sha-<7 chars>`), garantindo rastreabilidade e facilitando rollback.

### 3. deploy.yml — Deploy ao Servidor

**Trigger**: workflow_dispatch (manual)

| Step | Ação | Fallback |
|------|------|----------|
| SSH check | Verificar conexão SSH ao servidor | Abort se falha |
| Backup pré-deploy | `docker compose exec backup /scripts/backup.sh` | — |
| Pull images | `docker compose pull` | — |
| Recreate | `docker compose up -d` | — |
| Health verify | Aguardar healthchecks (timeout 5min) | Rollback automático |

**Requisitos**: Conexão SSH bem-sucedida + acionamento manual (dupla confirmação).

### 4. rollback.yml — Rollback para Versão Anterior

**Trigger**: workflow_dispatch (manual)

| Step | Ação |
|------|------|
| Get previous tag | Consultar commit anterior no GHCR |
| Update compose | Atualizar tags no `.env` ou docker-compose |
| Pull previous | `docker compose pull` |
| Recreate | `docker compose up -d` |
| Verify | Aguardar healthchecks |

## Secrets Necessários

Configure os seguintes secrets no repositório GitHub (Settings → Secrets → Actions):

| Secret | Propósito | Exemplo |
|--------|-----------|---------|
| `SSH_PRIVATE_KEY` | Chave SSH para acesso ao servidor | Chave privada RSA/Ed25519 |
| `SERVER_HOST` | IP ou hostname do servidor | `203.0.113.50` |
| `SERVER_USER` | Usuário SSH no servidor | `deploy` |
| `GHCR_TOKEN` | Token para push no GitHub Container Registry | `ghp_xxxxxxxxxxxx` |

Secrets nunca são expostos em logs do workflow (mascarados automaticamente pelo GitHub Actions).

## Fluxo Completo

```
Desenvolvedor → Abre PR
    ↓
validate.yml executa:
    ✓ hadolint (Dockerfiles)
    ✓ shellcheck (scripts)
    ✓ docker compose config
    ✓ env check
    ✓ build test
    ✓ trivy scan
    ↓
PR aprovado → Merge para main
    ↓
build.yml executa:
    ✓ Build multi-stage (login, char, map, fluxcp)
    ✓ Tag com SHA curto
    ✓ Push para ghcr.io
    ↓
Admin decide fazer deploy → Aciona deploy.yml manualmente
    ↓
deploy.yml executa:
    ✓ Verifica SSH
    ✓ Backup pré-deploy
    ✓ Pull novas imagens
    ✓ Recreate containers
    ✓ Verifica healthchecks
    ↓
Se falha → rollback.yml (manual) ou rollback automático
```

## Segurança do Pipeline

- Secrets armazenados exclusivamente nos GitHub Secrets
- SSH via chave privada (nunca senha)
- Imagens assinadas via tag SHA (imutável)
- Trivy bloqueia merge se vulnerabilidades CRITICAL/HIGH
- Deploy requer ação manual (workflow_dispatch) — nunca automático
- Backup obrigatório antes de qualquer deploy

## Configuração do GHCR

### Autenticação

```bash
# Login local (para testes)
echo $GHCR_TOKEN | docker login ghcr.io -u USERNAME --password-stdin
```

### Imagens publicadas

| Imagem | Descrição |
|--------|-----------|
| `ghcr.io/m1crocorp/rathena-login:<sha>` | Login Server |
| `ghcr.io/m1crocorp/rathena-char:<sha>` | Char Server |
| `ghcr.io/m1crocorp/rathena-map:<sha>` | Map Server |
| `ghcr.io/m1crocorp/rathena-fluxcp:<sha>` | FluxCP Panel |

### Listar tags disponíveis

```bash
# Via GitHub CLI
gh api /user/packages/container/rathena-login/versions --jq '.[].metadata.container.tags[]'
```

## Validação de .env.example

O workflow valida que todas as variáveis referenciadas no `docker-compose.yml` e nos templates de configuração estão documentadas no `.env.example`:

```bash
# Script de validação (simplificado)
COMPOSE_VARS=$(grep -oP '\$\{(\w+)\}' docker-compose.yml | sort -u)
TEMPLATE_VARS=$(grep -oP '\$\{(\w+)\}' conf/templates/*.tmpl | sort -u)
ENV_VARS=$(grep -oP '^\w+=' .env.example | sed 's/=$//' | sort -u)

# Verificar que cada variável referenciada existe no .env.example
for var in $COMPOSE_VARS $TEMPLATE_VARS; do
    if ! echo "$ENV_VARS" | grep -q "^${var}$"; then
        echo "ERROR: $var referenciada mas não definida em .env.example"
        exit 1
    fi
done
```

## Troubleshooting

### Build falha no CI

1. Verificar logs do workflow no GitHub Actions
2. Erros comuns: dependência faltando no apt-get, rAthena com breaking change, timeout de build
3. Artefatos de erro são salvos automaticamente no workflow

### Deploy falha

1. Verificar conexão SSH: `ssh -i key deploy@server "echo ok"`
2. Verificar se backup pré-deploy completou
3. Verificar healthchecks: `docker compose ps` no servidor
4. Se necessário: acionar `rollback.yml`

### Trivy reporta vulnerabilidades

1. Verificar se são vulnerabilidades da imagem base (debian:bookworm-slim)
2. Se são do rAthena: aguardar patch ou avaliar risco
3. Se são da base: atualizar imagem base ou adicionar exceção documentada
