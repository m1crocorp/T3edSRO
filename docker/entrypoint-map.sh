#!/bin/bash
set -e

# =============================================================================
# rAthena Map Server Entrypoint
# Generates configuration files from templates using environment variables
# and starts the map-server process.
#
# Templates: /rathena/conf/templates/ (read-only volume)
# Output:    /rathena/conf/import/ (rAthena reads import/ directory for overrides)
# =============================================================================

IMPORT_DIR="/rathena/conf/import"

# Create import directory (rAthena loads configs from conf/import/ as overrides)
mkdir -p "${IMPORT_DIR}"

echo "[entrypoint-map] Generating configuration files from templates..."

# Generate inter_athena.conf
envsubst < /rathena/conf/templates/inter_athena.conf.tmpl > "${IMPORT_DIR}/inter_athena.conf"
echo "[entrypoint-map] Generated: inter_athena.conf"

# Generate map_athena.conf
envsubst < /rathena/conf/templates/map_athena.conf.tmpl > "${IMPORT_DIR}/map_athena.conf"
echo "[entrypoint-map] Generated: map_athena.conf"

echo "[entrypoint-map] Configuration generation complete. Starting map-server..."

exec ./map-server
