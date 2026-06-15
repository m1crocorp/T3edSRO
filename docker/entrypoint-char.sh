#!/bin/bash
set -e

# =============================================================================
# rAthena Char Server Entrypoint
# Generates configuration files from templates using environment variables
# and starts the char-server process.
#
# Templates: /rathena/conf/templates/ (read-only volume)
# Output:    /rathena/conf/import/ (rAthena reads import/ directory for overrides)
# =============================================================================

IMPORT_DIR="/rathena/conf/import"

# Create import directory (rAthena loads configs from conf/import/ as overrides)
mkdir -p "${IMPORT_DIR}"

echo "[entrypoint-char] Generating configuration files from templates..."

# Generate inter_athena.conf
envsubst < /rathena/conf/templates/inter_athena.conf.tmpl > "${IMPORT_DIR}/inter_athena.conf"
echo "[entrypoint-char] Generated: inter_athena.conf"

# Generate char_athena.conf
envsubst < /rathena/conf/templates/char_athena.conf.tmpl > "${IMPORT_DIR}/char_athena.conf"
echo "[entrypoint-char] Generated: char_athena.conf"

echo "[entrypoint-char] Configuration generation complete. Starting char-server..."

exec ./char-server
