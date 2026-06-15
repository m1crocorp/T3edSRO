#!/bin/bash
set -e

# =============================================================================
# rAthena Map Server Entrypoint
# Generates configuration overrides from templates using environment variables.
#
# rAthena reads conf/map_athena.conf which imports conf/import/map_conf.txt
# =============================================================================

IMPORT_DIR="/rathena/conf/import"

mkdir -p "${IMPORT_DIR}"

echo "[entrypoint-map] Generating configuration files from templates..."

# Generate inter_conf.txt (database connection overrides)
envsubst < /rathena/conf/templates/inter_athena.conf.tmpl > "${IMPORT_DIR}/inter_conf.txt"
echo "[entrypoint-map] Generated: inter_conf.txt"

# Generate map_conf.txt (map server overrides)
envsubst < /rathena/conf/templates/map_athena.conf.tmpl > "${IMPORT_DIR}/map_conf.txt"
echo "[entrypoint-map] Generated: map_conf.txt"

echo "[entrypoint-map] Configuration generation complete. Starting map-server..."

exec ./map-server
