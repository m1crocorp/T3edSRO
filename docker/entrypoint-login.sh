#!/bin/bash
set -e

# =============================================================================
# rAthena Login Server Entrypoint
# Generates configuration files from templates using environment variables
# and starts the login-server process.
#
# Templates: /rathena/conf/templates/ (read-only volume)
# Output:    /rathena/conf/generated/ (tmpfs mount)
# =============================================================================

CONFIG_DIR="/rathena/conf/generated"

# Create generated config directory if it doesn't exist (tmpfs)
mkdir -p "${CONFIG_DIR}"

echo "[entrypoint-login] Generating configuration files from templates..."

# Generate inter_athena.conf (shared across all servers)
envsubst < /rathena/conf/templates/inter_athena.conf.tmpl > "${CONFIG_DIR}/inter_athena.conf"
echo "[entrypoint-login] Generated: inter_athena.conf"

# Generate login_athena.conf (login-server specific)
envsubst < /rathena/conf/templates/login_athena.conf.tmpl > "${CONFIG_DIR}/login_athena.conf"
echo "[entrypoint-login] Generated: login_athena.conf"

echo "[entrypoint-login] Configuration generation complete. Starting login-server..."

# Replace shell with login-server process, pointing to generated configs
exec ./login-server --conf "${CONFIG_DIR}/"
