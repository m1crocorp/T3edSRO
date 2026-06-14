#!/bin/bash
set -e

# =============================================================================
# rAthena Char Server Entrypoint
# Generates configuration files from templates using environment variables
# and starts the char-server process.
#
# Templates: /rathena/conf/templates/ (read-only volume)
# Output:    /rathena/conf/generated/ (tmpfs mount)
# =============================================================================

CONFIG_DIR="/rathena/conf/generated"

# Create generated config directory if it doesn't exist (tmpfs)
mkdir -p "${CONFIG_DIR}"

echo "[entrypoint-char] Generating configuration files from templates..."

# Generate inter_athena.conf (shared across all servers)
envsubst < /rathena/conf/templates/inter_athena.conf.tmpl > "${CONFIG_DIR}/inter_athena.conf"
echo "[entrypoint-char] Generated: inter_athena.conf"

# Generate char_athena.conf (char-server specific)
envsubst < /rathena/conf/templates/char_athena.conf.tmpl > "${CONFIG_DIR}/char_athena.conf"
echo "[entrypoint-char] Generated: char_athena.conf"

echo "[entrypoint-char] Configuration generation complete. Starting char-server..."

# Replace shell with char-server process, pointing to generated configs
exec ./char-server --conf "${CONFIG_DIR}/"
