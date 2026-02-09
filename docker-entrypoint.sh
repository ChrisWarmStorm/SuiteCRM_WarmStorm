#!/usr/bin/env bash
set -euo pipefail

PORT="${PORT:-8080}"

APP_ROOT="${APP_ROOT:-}"
DOCROOT="${DOCROOT:-}"

APP_ROOT_DEFAULTED=0
DOCROOT_DEFAULTED=0

if [ -z "${APP_ROOT}" ]; then
  APP_ROOT="/var/www/html"
  APP_ROOT_DEFAULTED=1
fi
if [ -z "${DOCROOT}" ]; then
  DOCROOT="/var/www/html"
  DOCROOT_DEFAULTED=1
fi

if [ "${DOCROOT_DEFAULTED}" -eq 1 ] && [ -d /var/www/html/public ]; then
  DOCROOT="/var/www/html/public"
fi

if [ "${APP_ROOT_DEFAULTED}" -eq 1 ]; then
  if [ -d /var/www/html/public ]; then
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
<Directory ${APP_ROOT}>
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
CONFIG_TEMPLATE_PATH="${APP_ROOT}/config_override.php.dist"

mkdir -p "${APP_ROOT}/cache" "${APP_ROOT}/custom" "${APP_ROOT}/data" "${APP_ROOT}/upload"
mkdir -p "${PERSIST_CONFIG_DIR}"

if ! chown -R www-data:www-data "${PERSIST_CONFIG_DIR}"; then
  echo "[entrypoint] Warning: failed to chown ${PERSIST_CONFIG_DIR}"
fi
if ! chmod 775 "${PERSIST_CONFIG_DIR}"; then
  echo "[entrypoint] Warning: failed to chmod 775 ${PERSIST_CONFIG_DIR}"
fi
if [ "${PERSIST_CONFIG_DIR}" != "/var/www/html/custom" ]; then
  if ! chown -R www-data:www-data "/var/www/html/custom"; then
    echo "[entrypoint] Warning: failed to chown /var/www/html/custom"
  fi
  if ! chmod 775 "/var/www/html/custom"; then
    echo "[entrypoint] Warning: failed to chmod 775 /var/www/html/custom"
  fi
fi

echo "[entrypoint] Persisting config to: ${PERSIST_CONFIG_DIR}"

if [ -f "${APP_ROOT}/config.php" ] && [ ! -L "${APP_ROOT}/config.php" ]; then
  mv "${APP_ROOT}/config.php" "${PERSIST_CONFIG_DIR}/config.php.bak.$(date +%s)"
fi

if [ -f "${APP_ROOT}/config_override.php" ] && [ ! -L "${APP_ROOT}/config_override.php" ]; then
  mv "${APP_ROOT}/config_override.php" "${PERSIST_CONFIG_DIR}/config_override.php.bak.$(date +%s)"
fi

if [ ! -f "${PERSIST_CONFIG_DIR}/config.php" ]; then
  install -o www-data -g www-data -m 664 /dev/null "${PERSIST_CONFIG_DIR}/config.php"
fi

if [ ! -f "${PERSIST_CONFIG_DIR}/config_override.php" ]; then
  install -o www-data -g www-data -m 664 /dev/null "${PERSIST_CONFIG_DIR}/config_override.php"
fi
if [ ! -s "${PERSIST_CONFIG_DIR}/config_override.php" ] && [ -f "${CONFIG_TEMPLATE_PATH}" ]; then
  if ! su -s /bin/sh www-data -c "cp '${CONFIG_TEMPLATE_PATH}' '${PERSIST_CONFIG_DIR}/config_override.php'"; then
    echo "[entrypoint] Warning: failed to seed config_override.php from ${CONFIG_TEMPLATE_PATH}"
  fi
fi

ln -sfn "${PERSIST_CONFIG_DIR}/config.php" "${APP_ROOT}/config.php"
ln -sfn "${PERSIST_CONFIG_DIR}/config_override.php" "${APP_ROOT}/config_override.php"

resolved_config="$(readlink -f "${APP_ROOT}/config.php" 2>/dev/null || true)"
if [ -z "${resolved_config}" ]; then
  resolved_config="${PERSIST_CONFIG_DIR}/config.php"
fi
resolved_override="$(readlink -f "${APP_ROOT}/config_override.php" 2>/dev/null || true)"
if [ -z "${resolved_override}" ]; then
  resolved_override="${PERSIST_CONFIG_DIR}/config_override.php"
fi
echo "[entrypoint] config.php -> ${resolved_config} (symlink)"
echo "[entrypoint] config_override.php -> ${resolved_override} (symlink)"

chown -R www-data:www-data "${APP_ROOT}/cache" "${APP_ROOT}/data" "${APP_ROOT}/upload"
chmod -R u+rwX,g+rwX "${APP_ROOT}/cache" "${APP_ROOT}/data" "${APP_ROOT}/upload"
chown -R www-data:www-data "${APP_ROOT}/custom"
chmod -R u+rwX,g+rwX "${APP_ROOT}/custom"

config_path="${APP_ROOT}/config.php"
override_path="${APP_ROOT}/config_override.php"
check_output="$(su -s /bin/sh www-data -c "php -r 'clearstatcache(); \$config=\"${config_path}\"; \$override=\"${override_path}\"; echo \"CONFIG_WRITABLE=\".(is_writable(\$config)?\"1\":\"0\").\" CONFIG_READABLE=\".(is_readable(\$config)?\"1\":\"0\").\"\\n\"; echo \"OVERRIDE_WRITABLE=\".(is_writable(\$override)?\"1\":\"0\").\" OVERRIDE_READABLE=\".(is_readable(\$override)?\"1\":\"0\").\"\\n\";'")"
printf '%s\n' "${check_output}"
config_ok="$(printf '%s' "${check_output}" | grep -c 'CONFIG_WRITABLE=1 CONFIG_READABLE=1' || true)"
override_ok="$(printf '%s' "${check_output}" | grep -c 'OVERRIDE_WRITABLE=1 OVERRIDE_READABLE=1' || true)"
if [ "${config_ok}" -ne 1 ] || [ "${override_ok}" -ne 1 ]; then
  echo "[entrypoint] Config access check failed"
  echo "[entrypoint] www-data uid/gid:"
  su -s /bin/sh www-data -c 'id -u; id -g' || true
  echo "[entrypoint] Root + persisted config file details:"
  ls -la "${APP_ROOT}/config.php" "${APP_ROOT}/config_override.php" "${PERSIST_CONFIG_DIR}/config.php" "${PERSIST_CONFIG_DIR}/config_override.php" || true
  if command -v stat >/dev/null 2>&1; then
    stat "${APP_ROOT}/config.php" "${APP_ROOT}/config_override.php" "${PERSIST_CONFIG_DIR}/config.php" "${PERSIST_CONFIG_DIR}/config_override.php" || true
  fi
  exit 1
fi

config_size="$(su -s /bin/sh www-data -c "wc -c < '${config_path}' 2>/dev/null | tr -d ' '")"
case "${config_size}" in
  ''|*[!0-9]*) config_size="0" ;;
esac

config_write_test=1
if [ "${config_size}" = "0" ]; then
  if su -s /bin/sh www-data -c "CONFIG_PATH='${config_path}' php -r 'exit(file_put_contents(getenv(\"CONFIG_PATH\"), \"<?php\\n// bootstrap\\n\")===false?1:0);'"; then
    if ! su -s /bin/sh www-data -c "CONFIG_PATH='${config_path}' php -r 'file_put_contents(getenv(\"CONFIG_PATH\"), \"\");'"; then
      config_write_test=0
    fi
  else
    config_write_test=0
  fi
fi

override_write_test=1
if ! su -s /bin/sh www-data -c "OVERRIDE_PATH='${override_path}' php -r '\$p=getenv(\"OVERRIDE_PATH\"); \$orig=@file_get_contents(\$p); if(\$orig===false){exit(1);} if(file_put_contents(\$p, \$orig.\"\\n// write test\\n\")===false){exit(1);} if(file_put_contents(\$p, \$orig)===false){exit(1);} exit(0);'"; then
  override_write_test=0
fi

echo "CONFIG_WRITE_TEST=${config_write_test}"
echo "OVERRIDE_WRITE_TEST=${override_write_test}"

if [ "${config_write_test}" -ne 1 ] || [ "${override_write_test}" -ne 1 ]; then
  echo "[entrypoint] Config write test failed"
  echo "[entrypoint] www-data uid/gid:"
  su -s /bin/sh www-data -c 'id -u; id -g' || true
  echo "[entrypoint] Root + persisted config file details:"
  ls -la "${APP_ROOT}/config.php" "${APP_ROOT}/config_override.php" "${PERSIST_CONFIG_DIR}/config.php" "${PERSIST_CONFIG_DIR}/config_override.php" || true
  if command -v stat >/dev/null 2>&1; then
    stat "${APP_ROOT}/config.php" "${APP_ROOT}/config_override.php" "${PERSIST_CONFIG_DIR}/config.php" "${PERSIST_CONFIG_DIR}/config_override.php" || true
  fi
  exit 1
fi

SUITECRM_DISABLE_INSTALLER="${SUITECRM_DISABLE_INSTALLER:-1}"
installer_disable_reason=""
if [ "${SUITECRM_DISABLE_INSTALLER}" = "0" ]; then
  installer_disable_reason="disabled by env"
else
  if su -s /bin/sh www-data -c "test -r '${APP_ROOT}/config.php'"; then
    config_size_bytes="$(su -s /bin/sh www-data -c "wc -c < '${APP_ROOT}/config.php' 2>/dev/null | tr -d ' '")"
    case "${config_size_bytes}" in
      ''|*[!0-9]*) config_size_bytes="0" ;;
    esac
    if [ "${config_size_bytes}" -le 2048 ]; then
      installer_disable_reason="small config"
    else
      if su -s /bin/sh www-data -c "grep -q -E \"installer_locked.*(true|1)\" '${APP_ROOT}/config.php'"; then
        if [ -d "${APP_ROOT}/install" ] && [ ! -e "${APP_ROOT}/install.disabled" ]; then
          mv "${APP_ROOT}/install" "${APP_ROOT}/install.disabled"
          su -s /bin/sh www-data -c "touch '${PERSIST_CONFIG_DIR}/install.disabled.marker'" || true
          echo "[entrypoint] Installer locked; disabled ${APP_ROOT}/install"
        fi
        installer_disable_reason=""
      else
        installer_disable_reason="missing lock"
      fi
    fi
  else
    installer_disable_reason="missing lock"
  fi
fi
if [ -n "${installer_disable_reason}" ]; then
  echo "[entrypoint] Installer not disabled (reason: ${installer_disable_reason})"
fi

echo "[entrypoint] Apache listening on: ${PORT}"
echo "[entrypoint] DocumentRoot: ${DOCROOT}"
echo "[entrypoint] APP_ROOT: ${APP_ROOT}"
echo "[entrypoint] PERSIST_CONFIG_DIR: ${PERSIST_CONFIG_DIR}"
php_info="$(php -r 'echo "upload_max_filesize=".ini_get("upload_max_filesize")."\n"; echo "post_max_size=".ini_get("post_max_size")."\n"; echo "memory_limit=".ini_get("memory_limit")."\n"; echo "output_buffering=".ini_get("output_buffering")."\n"; echo "display_errors=".ini_get("display_errors")."\n";')"
while IFS= read -r line; do
  if [ -n "${line}" ]; then
    echo "[entrypoint] PHP: ${line}"
  fi
done <<< "${php_info}"
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
