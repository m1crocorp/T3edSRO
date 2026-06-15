#!/bin/bash
set -e

# =============================================================================
# rAthena Login Server Entrypoint
# Generates configuration overrides from templates using environment variables.
#
# rAthena reads conf/inter_athena.conf which imports conf/import/inter_conf.txt
# and conf/login_athena.conf which imports conf/import/login_conf.txt
# We generate these import files with values from environment variables.
# =============================================================================

IMPORT_DIR="/rathena/conf/import"

mkdir -p "${IMPORT_DIR}"

echo "[entrypoint-login] Generating configuration files from templates..."

# Generate inter_conf.txt (database connection overrides)
envsubst < /rathena/conf/templates/inter_athena.conf.tmpl > "${IMPORT_DIR}/inter_conf.txt"
echo "[entrypoint-login] Generated: inter_conf.txt"

# Generate login_conf.txt (login server overrides)
envsubst < /rathena/conf/templates/login_athena.conf.tmpl > "${IMPORT_DIR}/login_conf.txt"
echo "[entrypoint-login] Generated: login_conf.txt"

echo "[entrypoint-login] Configuration generation complete. Starting login-server..."

exec ./login-server
