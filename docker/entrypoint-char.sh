#!/bin/bash
set -e

# =============================================================================
# rAthena Char Server Entrypoint
# Generates configuration overrides from templates using environment variables.
#
# rAthena reads conf/char_athena.conf which imports conf/import/char_conf.txt
# =============================================================================

IMPORT_DIR="/rathena/conf/import"

mkdir -p "${IMPORT_DIR}"

echo "[entrypoint-char] Generating configuration files from templates..."

# Generate inter_conf.txt (database connection overrides)
envsubst < /rathena/conf/templates/inter_athena.conf.tmpl > "${IMPORT_DIR}/inter_conf.txt"
echo "[entrypoint-char] Generated: inter_conf.txt"

# Generate char_conf.txt (char server overrides)
envsubst < /rathena/conf/templates/char_athena.conf.tmpl > "${IMPORT_DIR}/char_conf.txt"
echo "[entrypoint-char] Generated: char_conf.txt"

echo "[entrypoint-char] Configuration generation complete. Starting char-server..."

exec ./char-server
