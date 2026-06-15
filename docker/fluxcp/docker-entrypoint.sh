#!/bin/bash
set -e

# ============================================================
# FluxCP Docker Entrypoint
# Configures FluxCP database connection and server settings
# via environment variables at container startup.
#
# Features:
# - Dynamic config generation from environment variables
# - Friendly error page when MariaDB is unavailable (Req 13.5)
# - Automatic retry without exposing internal details
# ============================================================

FLUXCP_DIR="/var/www/html/fluxcp"
CONFIG_FILE="${FLUXCP_DIR}/config/application.php"
SERVERS_FILE="${FLUXCP_DIR}/config/servers.php"
MAINTENANCE_DIR="${FLUXCP_DIR}/maintenance"
DB_CHECK_FILE="${MAINTENANCE_DIR}/db_check.php"

# Default values
: "${DB_HOST:=mariadb}"
: "${FLUXCP_DB_USER:=fluxcp}"
: "${FLUXCP_DB_PASSWORD:=changeme}"
: "${RATHENA_DB_NAME:=ragnarok}"
: "${FLUXCP_SERVER_NAME:=${SERVER_NAME:-rAthena Server}}"
: "${FLUXCP_INSTALLER_DISABLED:=true}"

# ============================================================
# Create friendly error page (Requirement 13.5)
# Does NOT expose internal connection details, error codes,
# or database credentials.
# ============================================================
create_error_page() {
    mkdir -p "${MAINTENANCE_DIR}"

    cat > "${MAINTENANCE_DIR}/unavailable.html" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Serviço Temporariamente Indisponível</title>
    <meta http-equiv="refresh" content="30">
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #1a1a2e 0%, #16213e 50%, #0f3460 100%);
            color: #e0e0e0;
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .container {
            text-align: center;
            padding: 2rem;
            max-width: 500px;
        }
        .icon {
            font-size: 4rem;
            margin-bottom: 1.5rem;
            animation: pulse 2s infinite;
        }
        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.5; }
        }
        h1 {
            font-size: 1.5rem;
            margin-bottom: 1rem;
            color: #ffffff;
        }
        p {
            font-size: 1rem;
            line-height: 1.6;
            margin-bottom: 1rem;
            color: #b0b0b0;
        }
        .retry-info {
            margin-top: 1.5rem;
            padding: 1rem;
            background: rgba(255, 255, 255, 0.05);
            border-radius: 8px;
            border: 1px solid rgba(255, 255, 255, 0.1);
        }
        .retry-info p {
            font-size: 0.875rem;
            color: #909090;
            margin: 0;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="icon">⚙️</div>
        <h1>Serviço Temporariamente Indisponível</h1>
        <p>O painel de controle está em manutenção ou aguardando a inicialização de serviços internos.</p>
        <p>Por favor, tente novamente em alguns instantes.</p>
        <div class="retry-info">
            <p>Esta página será atualizada automaticamente em 30 segundos.</p>
        </div>
    </div>
</body>
</html>
HTMLEOF

    # PHP script that checks DB connectivity and shows error page if unavailable
    # This script does NOT expose connection details in error output
    cat > "${DB_CHECK_FILE}" << 'PHPEOF'
<?php
/**
 * Database connectivity check for FluxCP (Requirement 13.5)
 * Shows a friendly maintenance page when MariaDB is unavailable.
 * Does NOT expose internal connection details, passwords, or error codes.
 */

$db_host = getenv('DB_HOST') ?: 'mariadb';
$db_user = getenv('FLUXCP_DB_USER') ?: 'fluxcp';
$db_pass = getenv('FLUXCP_DB_PASSWORD') ?: '';
$db_name = getenv('RATHENA_DB_NAME') ?: 'ragnarok';

// Suppress error output to prevent leaking connection details
$connection = @mysqli_connect($db_host, $db_user, $db_pass, $db_name, 3306);

if (!$connection) {
    // Log the actual error server-side only (not exposed to user)
    error_log('[FluxCP] Database connection failed - showing maintenance page');

    http_response_code(503);
    header('Retry-After: 30');
    readfile(__DIR__ . '/unavailable.html');
    exit;
}

// Connection is healthy, close test connection
mysqli_close($connection);

// Database is available - do nothing, let FluxCP handle the request normally
PHPEOF

    chown -R www-data:www-data "${MAINTENANCE_DIR}"
}

# ============================================================
# Configure PHP auto_prepend_file for DB connectivity check
# This runs the check before every request without modifying
# FluxCP source code directly.
# ============================================================
configure_db_check() {
    local php_ini_dir
    php_ini_dir="$(php -r 'echo PHP_INI_DIR;' 2>/dev/null || echo '/usr/local/etc/php')"

    # Ensure conf.d directory exists
    mkdir -p "${php_ini_dir}/conf.d"

    # Create a custom ini that prepends the DB check script
    cat > "${php_ini_dir}/conf.d/99-fluxcp-dbcheck.ini" << INIEOF
; FluxCP database connectivity check (Requirement 13.5)
; Displays friendly error page when MariaDB is unavailable
auto_prepend_file = ${DB_CHECK_FILE}
INIEOF

    echo "[FluxCP] Database connectivity check configured (auto_prepend_file)"
}

# ============================================================
# Generate FluxCP configuration files
# ============================================================
generate_config() {
    # Wait for config directory
    if [ ! -d "${FLUXCP_DIR}/config" ]; then
        echo "[FluxCP] ERROR: Config directory not found at ${FLUXCP_DIR}/config"
        exit 1
    fi

    # Create import directory (FluxCP merges import configs over defaults)
    mkdir -p "${FLUXCP_DIR}/config/import"

    # Generate import/application.php (overrides only specific keys)
    echo "[FluxCP] Generating import/application.php (overrides)..."
    cat > "${FLUXCP_DIR}/config/import/application.php" << PHPEOF
<?php
// FluxCP Application Configuration Overrides
// Auto-generated by docker-entrypoint.sh from environment variables
// These values are merged over the default application.php

return array(
    'ServerName'        => '${FLUXCP_SERVER_NAME}',
    'BaseURI'           => '',
    'InstallerDisabled' => ${FLUXCP_INSTALLER_DISABLED},
);
PHPEOF

    # Generate import/servers.php (overrides server connection)
    echo "[FluxCP] Generating import/servers.php..."
    cat > "${FLUXCP_DIR}/config/import/servers.php" << PHPEOF
<?php
// FluxCP Server Configuration
// Auto-generated by docker-entrypoint.sh from environment variables

\$GameServers = array();
\$GameServers[0] = array(
    'ServerName'     => '${FLUXCP_SERVER_NAME}',
    'Hostname'       => '${DB_HOST}',
    'Username'       => '${FLUXCP_DB_USER}',
    'Password'       => '${FLUXCP_DB_PASSWORD}',
    'Database'       => '${RATHENA_DB_NAME}',
    'Port'           => 3306,
    'Charset'        => 'utf8mb4',
    'DbDriver'       => 'mysql',

    // Login server configuration
    'LoginServer' => array(
        'Address'  => '${DB_HOST}',
        'Port'     => 6900,
    ),

    // Char server configuration
    'CharServer' => array(
        'Address'  => '${DB_HOST}',
        'Port'     => 6121,
    ),

    // Map server configuration
    'MapServer' => array(
        'Address'  => '${DB_HOST}',
        'Port'     => 5121,
    ),

    // Database tables
    'SubDatabases' => array(
        'rAthena' => array(
            'Hostname' => '${DB_HOST}',
            'Username' => '${FLUXCP_DB_USER}',
            'Password' => '${FLUXCP_DB_PASSWORD}',
            'Database' => '${RATHENA_DB_NAME}',
            'Persistent' => false,
        ),
        'Logs' => array(
            'Hostname' => '${DB_HOST}',
            'Username' => '${FLUXCP_DB_USER}',
            'Password' => '${FLUXCP_DB_PASSWORD}',
            'Database' => '${RATHENA_DB_NAME}_log',
            'Persistent' => false,
        ),
    ),
);
PHPEOF

    chown -R www-data:www-data "${FLUXCP_DIR}/config/import"
}

# ============================================================
# Main execution
# ============================================================
echo "[FluxCP] Starting container initialization..."

# Step 1: Create friendly error page
create_error_page

# Step 2: Configure automatic DB connectivity check
configure_db_check

# Step 3: Generate FluxCP configuration from environment variables
generate_config

# Step 4: Ensure data directory has correct permissions (volume mount may reset)
chown -R www-data:www-data /var/www/html/data 2>/dev/null || true
chmod -R 775 /var/www/html/data 2>/dev/null || true

echo "[FluxCP] Configuration complete. Starting Apache..."

# Execute the main command (apache2-foreground)
exec "$@"
