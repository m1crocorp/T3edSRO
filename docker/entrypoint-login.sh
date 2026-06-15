#!/bin/bash
set -e

# =============================================================================
# rAthena Login Server Entrypoint
# Generates configuration files from templates using environment variables
# and starts the login-server process.
#
# Templates: /rathena/conf/templates/ (read-only volume)
# Output:    /rathena/conf/import/ (rAthena reads import/ directory for overrides)
# =============================================================================

IMPORT_DIR="/rathena/conf/import"

# Create import directory (rAthena loads configs from conf/import/ as overrides)
mkdir -p "${IMPORT_DIR}"

echo "[entrypoint-login] Generating configuration files from templates..."

# Generate inter_athena.conf
envsubst < /rathena/conf/templates/inter_athena.conf.tmpl > "${IMPORT_DIR}/inter_athena.conf"
echo "[entrypoint-login] Generated: inter_athena.conf"

# Generate login_athena.conf
envsubst < /rathena/conf/templates/login_athena.conf.tmpl > "${IMPORT_DIR}/login_athena.conf"
echo "[entrypoint-login] Generated: login_athena.conf"

echo "[entrypoint-login] Configuration generation complete. Starting login-server..."

# rAthena reads configs from ./conf/ relative to binary (no --conf flag)
exec ./login-server
