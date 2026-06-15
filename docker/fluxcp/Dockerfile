# ============================================================
# FluxCP - Painel de Controle Web para rAthena
# Base: PHP 8.2 + Apache
# Requirements: 13.1, 13.2, 13.3, 13.4, 13.5, 13.6
# ============================================================
FROM php:8.2-apache

LABEL maintainer="rAthena Server Admin"
LABEL description="FluxCP - Web Control Panel for rAthena"

# Environment variables for database connection and customization
ENV DB_HOST=mariadb \
    FLUXCP_DB_USER=fluxcp \
    FLUXCP_DB_PASSWORD=changeme \
    RATHENA_DB_NAME=ragnarok \
    FLUXCP_SERVER_NAME="rAthena Server" \
    FLUXCP_BASE_URL="http://localhost" \
    FLUXCP_INSTALLER_DISABLED=true

# Install system dependencies and PHP extensions (mysql, gd, mbstring)
RUN apt-get update && apt-get install -y --no-install-recommends \
    libpng-dev \
    libjpeg62-turbo-dev \
    libfreetype6-dev \
    libonig-dev \
    curl \
    git \
    unzip \
    && docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        mysqli \
        pdo_mysql \
        gd \
        mbstring \
    && apt-get purge -y --auto-remove libpng-dev libjpeg62-turbo-dev libfreetype6-dev libonig-dev \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Enable Apache mod_rewrite for clean URLs
RUN a2enmod rewrite

# Clone FluxCP from official rAthena repository
RUN git clone --depth 1 https://github.com/rathena/FluxCP.git /var/www/html/fluxcp \
    && rm -rf /var/www/html/fluxcp/.git

# Configure Apache: set DocumentRoot to FluxCP and enable AllowOverride
RUN sed -i 's|DocumentRoot /var/www/html|DocumentRoot /var/www/html/fluxcp|g' \
    /etc/apache2/sites-available/000-default.conf \
    && sed -i '/<Directory \/var\/www\/>/,/<\/Directory>/ s/AllowOverride None/AllowOverride All/' /etc/apache2/apache2.conf \
    && printf '<Directory /var/www/html/fluxcp>\n\
    Options -Indexes +FollowSymLinks\n\
    AllowOverride All\n\
    Require all granted\n\
</Directory>\n' >> /etc/apache2/apache2.conf

# Create data directory for persistent uploads/configs (Requirement 13.6)
# The volume is mounted at /var/www/html/data via docker-compose
# Copy FluxCP's original data directory (schemas, etc.) to a default location,
# then symlink FluxCP's data path to the volume mount point.
# The entrypoint will copy defaults to volume on first run.
RUN mkdir -p /var/www/html/data /var/www/html/fluxcp-data-default \
    && cp -a /var/www/html/fluxcp/data/. /var/www/html/fluxcp-data-default/ \
    && rm -rf /var/www/html/fluxcp/data \
    && ln -s /var/www/html/data /var/www/html/fluxcp/data

# Create friendly error page for when MariaDB is unavailable (Requirement 13.5)
# This page does NOT expose internal details (connection strings, error codes, etc.)
RUN mkdir -p /var/www/html/fluxcp/maintenance
COPY docker-entrypoint.sh /usr/local/bin/docker-entrypoint.sh
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

# Set appropriate permissions
RUN chown -R www-data:www-data /var/www/html/fluxcp \
    && chmod -R 755 /var/www/html/fluxcp \
    && chown -R www-data:www-data /var/www/html/data \
    && chmod -R 775 /var/www/html/data

EXPOSE 80

# Healthcheck via curl (Requirement 13.5 - verify service is running)
HEALTHCHECK --interval=30s --timeout=10s --start-period=30s --retries=3 \
    CMD curl -f http://localhost:80/ || exit 1

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["apache2-foreground"]
