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
# Step 2: Create log file and ensure backup directory exists
# ---------------------------------------------------------------------------
CRON_SCHEDULE="${BACKUP_CRON_SCHEDULE:-0 4 * * *}"

touch /var/log/backup.log
mkdir -p /backups

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup service ready."
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Schedule: ${CRON_SCHEDULE}"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup target: /backups/"
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Database: ${DB_HOST:-mariadb}:${DB_PORT:-3306}"

# ---------------------------------------------------------------------------
# Step 3: Run backup loop using sleep (no cron dependency)
# Calculates seconds until next scheduled run (default 04:00 UTC daily).
# ---------------------------------------------------------------------------
calculate_seconds_until_next_run() {
    local target_hour="${BACKUP_HOUR:-4}"
    local target_min="${BACKUP_MIN:-0}"
    local now_epoch now_hour now_min target_epoch

    now_epoch=$(date +%s)
    now_hour=$(date -u +%H | sed 's/^0//')
    now_min=$(date -u +%M | sed 's/^0//')

    # Calculate target epoch for today
    target_epoch=$(date -u -d "$(date -u +%Y-%m-%d) ${target_hour}:${target_min}:00" +%s 2>/dev/null || echo "0")

    if [ "$target_epoch" -le "$now_epoch" ]; then
        # Target already passed today, schedule for tomorrow
        target_epoch=$((target_epoch + 86400))
    fi

    echo $((target_epoch - now_epoch))
}

# Parse hour/min from BACKUP_CRON_SCHEDULE (format: "MIN HOUR * * *")
BACKUP_MIN=$(echo "${CRON_SCHEDULE}" | awk '{print $1}')
BACKUP_HOUR=$(echo "${CRON_SCHEDULE}" | awk '{print $2}')

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup will run daily at ${BACKUP_HOUR}:$(printf '%02d' ${BACKUP_MIN}) UTC"

while true; do
    SLEEP_SECONDS=$(calculate_seconds_until_next_run)
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Next backup in ${SLEEP_SECONDS} seconds ($(date -u -d @$(($(date +%s) + SLEEP_SECONDS)) '+%Y-%m-%d %H:%M UTC' 2>/dev/null || echo 'soon'))"
    sleep "${SLEEP_SECONDS}"

    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Starting scheduled backup..."
    . /etc/environment
    /scripts/backup.sh >> /var/log/backup.log 2>&1 || true
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] Backup cycle complete."

    # Sleep 60s to avoid re-triggering in the same minute
    sleep 60
done

