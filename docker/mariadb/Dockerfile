FROM mariadb:11.4

# Criar diretório conf.d gravável (o original será montado em conf.d.ro como read-only)
RUN mkdir -p /etc/mysql/conf.d

COPY mariadb-entrypoint-wrapper.sh /usr/local/bin/mariadb-entrypoint-wrapper.sh
RUN chmod +x /usr/local/bin/mariadb-entrypoint-wrapper.sh

ENTRYPOINT ["mariadb-entrypoint-wrapper.sh"]
CMD ["mariadbd"]
