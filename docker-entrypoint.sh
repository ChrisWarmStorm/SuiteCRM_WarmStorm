#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-8080}"

APP_ROOT="/var/www/html"
DOCROOT="/var/www/html"

if [ -d /var/www/html/public ]; then
  DOCROOT="/var/www/html/public"
  if [ -d /var/www/html/public/legacy ]; then
    APP_ROOT="/var/www/html/public/legacy"
  else
    APP_ROOT="/var/www/html/public"
  fi
else
  if [ -d /var/www/html/legacy ]; then
    APP_ROOT="/var/www/html/legacy"
  fi
fi

if [ -f /etc/apache2/ports.conf ]; then
  for f in /etc/apache2/ports.conf \
           /etc/apache2/apache2.conf \
           /etc/apache2/conf-available/*.conf \
           /etc/apache2/conf-enabled/*.conf \
           /etc/apache2/sites-available/*.conf \
           /etc/apache2/sites-enabled/*.conf; do
    if [ -f "$f" ]; then
      sed -i -E '/^[[:space:]]*Listen[[:space:]]+/d' "$f"
    fi
  done
  echo "Listen ${PORT}" >> /etc/apache2/ports.conf
fi

for vhost in /etc/apache2/sites-available/*.conf /etc/apache2/sites-enabled/*.conf; do
  if [ -f "$vhost" ]; then
    sed -i -E "s/<VirtualHost[[:space:]]+\\*:[0-9]+>/<VirtualHost *:${PORT}>/g" "$vhost"
    sed -i -E "s#^[[:space:]]*DocumentRoot .*#DocumentRoot ${DOCROOT}#" "$vhost"
  fi
done

cat > /etc/apache2/conf-available/suitecrm.conf <<EOF
<Directory ${DOCROOT}>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>
SetEnvIfNoCase X-Forwarded-Proto https HTTPS=on
SetEnvIfNoCase X-Forwarded-SSL on HTTPS=on
EOF

if [ -e /etc/apache2/conf-enabled/suitecrm.conf ] && [ ! -L /etc/apache2/conf-enabled/suitecrm.conf ]; then
  rm -f /etc/apache2/conf-enabled/suitecrm.conf
fi
ln -sfn ../conf-available/suitecrm.conf /etc/apache2/conf-enabled/suitecrm.conf

if ! grep -q "ServerName" /etc/apache2/apache2.conf; then
  echo "ServerName localhost" > /etc/apache2/conf-available/servername.conf
  a2enconf servername >/dev/null
fi

PERSIST_CONFIG_DIR="${PERSIST_CONFIG_DIR:-${APP_ROOT}/custom}"
CONFIG_TEMPLATE_PATH="/var/www/html/config_override.php.dist"

mkdir -p "${APP_ROOT}/cache" "${APP_ROOT}/custom" "${APP_ROOT}/data" "${APP_ROOT}/upload"
mkdir -p "${PERSIST_CONFIG_DIR}"

for cfg in config.php config_override.php; do
  target="${PERSIST_CONFIG_DIR}/${cfg}"
  if [ -f "${APP_ROOT}/${cfg}" ] && [ ! -f "${target}" ]; then
    cp "${APP_ROOT}/${cfg}" "${target}"
  fi
  if [ "${cfg}" = "config_override.php" ] && [ ! -f "${target}" ] && [ -f "${CONFIG_TEMPLATE_PATH}" ]; then
    cp "${CONFIG_TEMPLATE_PATH}" "${target}"
  fi
  if [ ! -L "${APP_ROOT}/${cfg}" ]; then
    if [ -f "${APP_ROOT}/${cfg}" ]; then
      rm -f "${APP_ROOT}/${cfg}"
    fi
    ln -s "${target}" "${APP_ROOT}/${cfg}"
  fi
done

chown -R www-data:www-data "${APP_ROOT}/cache" "${APP_ROOT}/custom" "${APP_ROOT}/data" "${APP_ROOT}/upload" "${PERSIST_CONFIG_DIR}"
chmod -R u+rwX,g+rwX "${APP_ROOT}/cache" "${APP_ROOT}/custom" "${APP_ROOT}/data" "${APP_ROOT}/upload" "${PERSIST_CONFIG_DIR}"

echo "[entrypoint] Apache listening on: ${PORT}"
echo "[entrypoint] DocumentRoot: ${DOCROOT}"
echo "[entrypoint] APP_ROOT: ${APP_ROOT}"
echo "[entrypoint] PERSIST_CONFIG_DIR: ${PERSIST_CONFIG_DIR}"
listen_lines="$(grep -R -n -E '^[[:space:]]*Listen[[:space:]]+' /etc/apache2 2>/dev/null | tr '\n' '; ')"
if [ -n "${listen_lines}" ]; then
  echo "[entrypoint] Effective Listen directives: ${listen_lines}"
else
  echo "[entrypoint] Effective Listen directives: none"
fi
if [ -f /etc/apache2/mods-enabled/rewrite.load ]; then
  echo "[entrypoint] Rewrite module enabled: true"
else
  echo "[entrypoint] Rewrite module enabled: false"
fi

a2dismod mpm_event mpm_worker >/dev/null 2>&1 || true
a2enmod mpm_prefork >/dev/null 2>&1 || true
echo "[entrypoint] Enabled MPM modules:"
ls -1 /etc/apache2/mods-enabled | grep '^mpm_' || true

if ! apache2ctl -t; then
  echo "[entrypoint] Apache config test failed"
  exit 1
fi

exec "$@"
