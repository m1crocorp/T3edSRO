#!/bin/bash
# ==============================================================================
# Backup Service Entrypoint
# ==============================================================================
# This script:
# 1. Exports container environment variables to /etc/environment so cron can
#    access them (cron does not inherit the container's environment by default)
# 2. Installs the crontab with the configured schedule
# 3. Starts the cron daemon in foreground
#
# Environment variables:
#   BACKUP_CRON_SCHEDULE - Cron expression for backup schedule (default: "0 4 * * *")
#   DB_HOST              - MariaDB host
#   DB_PORT              - MariaDB port
#   BACKUP_DB_USER       - Database user for backups
#   BACKUP_DB_PASSWORD   - Database password for backups
#   RATHENA_DB_NAME      - Main database name
#   RATHENA_LOG_DB_NAME  - Log database name
#   BACKUP_RETENTION_DAYS - Days to retain backups
#   BACKUP_WEBHOOK_URL   - Webhook URL for failure notifications
# ==============================================================================

set -e

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup service starting..."

# ---------------------------------------------------------------------------
# Step 1: Export environment variables for cron
# Cron jobs run in a minimal environment without access to container env vars.
# We dump all relevant variables to /etc/environment so they can be sourced
# by the cron job before executing the backup script.
# ---------------------------------------------------------------------------
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Exporting environment variables to /etc/environment..."

# Write environment variables in a format that can be sourced by sh/bash
cat > /etc/environment <<EOF
DB_HOST="${DB_HOST:-mariadb}"
DB_PORT="${DB_PORT:-3306}"
BACKUP_DB_USER="${BACKUP_DB_USER:-rathena_backup}"
BACKUP_DB_PASSWORD="${BACKUP_DB_PASSWORD:-}"
RATHENA_DB_NAME="${RATHENA_DB_NAME:-ragnarok}"
RATHENA_LOG_DB_NAME="${RATHENA_LOG_DB_NAME:-ragnarok_log}"
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-30}"
BACKUP_WEBHOOK_URL="${BACKUP_WEBHOOK_URL:-}"
BACKUP_CRON_SCHEDULE="${BACKUP_CRON_SCHEDULE:-0 4 * * *}"
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
EOF

# Secure the environment file (contains credentials)
chmod 0600 /etc/environment

# ---------------------------------------------------------------------------
# Step 2: Install crontab
# Use BACKUP_CRON_SCHEDULE env var if set, otherwise default to 04:00 UTC.
# The cron job sources /etc/environment before running the backup script to
# ensure all required variables are available.
# ---------------------------------------------------------------------------
CRON_SCHEDULE="${BACKUP_CRON_SCHEDULE:-0 4 * * *}"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Installing crontab with schedule: ${CRON_SCHEDULE}"

# Generate crontab dynamically with the configured schedule
# The '. /etc/environment' sources all env vars before executing backup.sh
cat > /etc/cron.d/rathena-backup <<EOF
# rAthena Backup - schedule: ${CRON_SCHEDULE}
${CRON_SCHEDULE} root . /etc/environment; /scripts/backup.sh >> /var/log/backup.log 2>&1
# Empty line required by cron
EOF

# Set proper permissions (cron requires 0644 for files in /etc/cron.d)
chmod 0644 /etc/cron.d/rathena-backup

# ---------------------------------------------------------------------------
# Step 3: Create log file and ensure backup directory exists
# ---------------------------------------------------------------------------
touch /var/log/backup.log
mkdir -p /backups

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup service ready."
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Schedule: ${CRON_SCHEDULE}"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup target: /backups/"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Database: ${DB_HOST:-mariadb}:${DB_PORT:-3306}"

# ---------------------------------------------------------------------------
# Step 4: Start cron in foreground
# The -f flag keeps cron in the foreground so Docker can track the process.
# This ensures the container stays running and Docker can detect if cron dies.
# ---------------------------------------------------------------------------
exec cron -f

