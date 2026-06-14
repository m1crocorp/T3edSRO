# TLS Certificates

Este diretório armazena os certificados TLS para o Zabbix Web Frontend (HTTPS na porta 443).

## Arquivos necessários

- `zabbix.crt` — Certificado público (PEM format)
- `zabbix.key` — Chave privada (PEM format)

## Gerando certificado self-signed (desenvolvimento)

```bash
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout zabbix.key -out zabbix.crt \
  -subj "/CN=zabbix.local/O=rAthena Server"
```

## Produção (Let's Encrypt)

Para produção, use certificados reais do Let's Encrypt:

```bash
certbot certonly --standalone -d seu-dominio.com
cp /etc/letsencrypt/live/seu-dominio.com/fullchain.pem ./certs/zabbix.crt
cp /etc/letsencrypt/live/seu-dominio.com/privkey.pem ./certs/zabbix.key
```

## Segurança

- **NUNCA** commite chaves privadas no repositório
- Adicione `certs/*.key` e `certs/*.crt` ao `.gitignore`
- Em produção, use secrets management ou mount de volume externo
