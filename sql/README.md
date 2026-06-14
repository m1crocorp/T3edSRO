# sql/ — Scripts de Inicialização do Banco de Dados

Este diretório contém os scripts SQL e shell de inicialização do MariaDB. Todo o conteúdo é montado em `/docker-entrypoint-initdb.d/` no container MariaDB e executado automaticamente **apenas na primeira inicialização** (quando o volume de dados está vazio).

## Ordem de Execução

A imagem oficial `mariadb:11.4` executa scripts em `/docker-entrypoint-initdb.d/` em **ordem alfabética**. A nomenclatura numérica garante a sequência correta:

| Arquivo | Tipo | Propósito |
|---------|------|-----------|
| `00-init.sh` | Shell | Cria bancos de dados, usuários e privilégios com senhas do `.env` |
| `00-setup-users.sql` | SQL | Versão SQL de referência (não executada diretamente — use como documentação) |
| `01-main.sql` | SQL | Schema principal do rAthena (tabelas do banco `ragnarok`) |
| `02-logs.sql` | SQL | Schema de logs do rAthena (tabelas do banco `ragnarok_log`) |

## Scripts do Repositório rAthena (main.sql e logs.sql)

Os arquivos de schema **não estão incluídos neste repositório** — eles vêm do repositório oficial do rAthena e devem ser copiados manualmente ou via script.

### Como obter os scripts:

```bash
# Clonar o repositório rAthena (shallow clone)
git clone --depth 1 https://github.com/rathena/rathena.git /tmp/rathena

# Copiar os scripts de schema para o diretório sql/
cp /tmp/rathena/sql/main.sql sql/01-main.sql
cp /tmp/rathena/sql/logs.sql sql/02-logs.sql

# Limpar o clone temporário
rm -rf /tmp/rathena
```

### Importante:

- Renomeie para `01-main.sql` e `02-logs.sql` para garantir execução **após** `00-init.sh` (que cria os bancos e usuários)
- Os scripts originais assumem que os bancos `ragnarok` e `ragnarok_log` já existem — o `00-init.sh` cria ambos
- Cada script deve usar `USE ragnarok;` ou `USE ragnarok_log;` no início. Se o script original não tiver isso, adicione manualmente:
  ```sql
  -- No início de 01-main.sql
  USE `ragnarok`;

  -- No início de 02-logs.sql
  USE `ragnarok_log`;
  ```

## Variáveis de Ambiente Necessárias

O script `00-init.sh` requer as seguintes variáveis definidas no `.env`:

| Variável | Propósito |
|----------|-----------|
| `MARIADB_ROOT_PASSWORD` | Senha root do MariaDB (obrigatória pela imagem Docker) |
| `RATHENA_DB_PASSWORD` | Senha do usuário `rathena` (operação dos servidores) |
| `BACKUP_DB_PASSWORD` | Senha do usuário `rathena_backup` (backup) |
| `FLUXCP_DB_PASSWORD` | Senha do usuário `fluxcp` (painel web) |
| `ZBX_DB_PASSWORD` | Senha do usuário `zabbix` (monitoramento) |

## Montagem no Docker Compose

No `docker-compose.yml`, o diretório é montado como read-only:

```yaml
services:
  mariadb:
    image: mariadb:11.4
    volumes:
      - ./sql:/docker-entrypoint-initdb.d:ro
      - rathena-db-data:/var/lib/mysql
    environment:
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD}
      RATHENA_DB_PASSWORD: ${RATHENA_DB_PASSWORD}
      BACKUP_DB_PASSWORD: ${BACKUP_DB_PASSWORD}
      FLUXCP_DB_PASSWORD: ${FLUXCP_DB_PASSWORD}
      ZBX_DB_PASSWORD: ${ZBX_DB_PASSWORD}
```

## Reinicialização do Banco

Os scripts em `/docker-entrypoint-initdb.d/` só executam quando o volume de dados está vazio. Para re-executar a inicialização:

```bash
# ATENÇÃO: Isso apaga todos os dados do banco!
docker compose down
docker volume rm ragnarok-online_rathena-db-data
docker compose up -d mariadb
```

Para ambientes existentes, execute alterações via `mariadb` CLI diretamente.
