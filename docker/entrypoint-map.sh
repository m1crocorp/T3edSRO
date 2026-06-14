#!/bin/bash
set -e

# =============================================================================
# rAthena Map Server Entrypoint
# Generates configuration files from templates using environment variables
# and starts the map-server process.
#
# Templates: /rathena/conf/templates/ (read-only volume)
# Output:    /rathena/conf/generated/ (tmpfs mount)
# =============================================================================

CONFIG_DIR="/rathena/conf/generated"

# Create generated config directory if it doesn't exist (tmpfs)
mkdir -p "${CONFIG_DIR}"

echo "[entrypoint-map] Generating configuration files from templates..."

# Generate inter_athena.conf (shared across all servers)
envsubst < /rathena/conf/templates/inter_athena.conf.tmpl > "${CONFIG_DIR}/inter_athena.conf"
echo "[entrypoint-map] Generated: inter_athena.conf"

# Generate map_athena.conf (map-server specific)
envsubst < /rathena/conf/templates/map_athena.conf.tmpl > "${CONFIG_DIR}/map_athena.conf"
echo "[entrypoint-map] Generated: map_athena.conf"

echo "[entrypoint-map] Configuration generation complete. Starting map-server..."

# Replace shell with map-server process, pointing to generated configs
exec ./map-server --conf "${CONFIG_DIR}/"
