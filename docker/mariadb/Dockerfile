FROM mariadb:11.4

COPY mariadb-entrypoint-wrapper.sh /usr/local/bin/mariadb-entrypoint-wrapper.sh
RUN chmod +x /usr/local/bin/mariadb-entrypoint-wrapper.sh

ENTRYPOINT ["mariadb-entrypoint-wrapper.sh"]
