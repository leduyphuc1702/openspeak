#!/bin/sh
# Renew the certificate through the existing port-80 web root, then restart the API if a new one was issued.
set -eu
ACME_WEBROOT=$(sed -n 's/^ACME_WEBROOT=//p' /etc/openspeak.env)
docker run --rm \
  -v /opt/openspeak/letsencrypt:/etc/letsencrypt \
  -v /opt/openspeak/letsencrypt-lib:/var/lib/letsencrypt \
  -v "$ACME_WEBROOT":/var/www/certbot \
  certbot/certbot:latest renew --quiet --webroot -w /var/www/certbot \
  --deploy-hook "touch /etc/letsencrypt/.renewed"
if [ -e /opt/openspeak/letsencrypt/.renewed ]; then
  rm /opt/openspeak/letsencrypt/.renewed
  systemctl restart openspeak
fi
