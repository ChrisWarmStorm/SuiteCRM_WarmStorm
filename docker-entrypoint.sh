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

servername_conf_enabled="/etc/apache2/conf-enabled/servername.conf"
if [ -e "${servername_conf_enabled}" ] && [ ! -L "${servername_conf_enabled}" ]; then
  echo "[entrypoint] WARN: Conf servername not properly enabled: ${servername_conf_enabled} is a real file; replacing"
  rm -f "${servername_conf_enabled}"
fi
if ! grep -q "ServerName" /etc/apache2/apache2.conf; then
  echo "ServerName localhost" > /etc/apache2/conf-available/servername.conf
  a2enconf servername >/dev/null 2>&1 || true
fi

railway_forwarded_conf="/etc/apache2/conf-available/railway-forwarded-https.conf"
if [ -f "${railway_forwarded_conf}" ]; then
  a2enconf railway-forwarded-https >/dev/null 2>&1 || true
  if [ -L /etc/apache2/conf-enabled/railway-forwarded-https.conf ]; then
    echo "[entrypoint] railway-forwarded-https enabled: 1"
  else
    echo "[entrypoint] railway-forwarded-https enabled: 0"
  fi
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

if [ -f "${PERSIST_CONFIG_DIR}/config.php" ]; then
  config_size_bytes="$(wc -c < "${PERSIST_CONFIG_DIR}/config.php" 2>/dev/null | tr -d ' ')"
  case "${config_size_bytes}" in
    ''|*[!0-9]*) config_size_bytes="0" ;;
  esac
  if [ "${config_size_bytes}" = "0" ]; then
    echo "[entrypoint] zero-byte persisted config.php detected; removing to avoid installer loop"
    rm -f "${PERSIST_CONFIG_DIR}/config.php"
  fi
fi

if [ -f "${PERSIST_CONFIG_DIR}/config_override.php" ] && [ ! -s "${PERSIST_CONFIG_DIR}/config_override.php" ] && [ -f "${CONFIG_TEMPLATE_PATH}" ]; then
  if ! su -s /bin/sh www-data -c "cp '${CONFIG_TEMPLATE_PATH}' '${PERSIST_CONFIG_DIR}/config_override.php'"; then
    echo "[entrypoint] Warning: failed to seed config_override.php from ${CONFIG_TEMPLATE_PATH}"
  fi
fi

suitecrm_site_url_raw="${SUITECRM_SITE_URL:-}"
if [ -n "${suitecrm_site_url_raw}" ]; then
  suitecrm_site_url="$(printf '%s' "${suitecrm_site_url_raw}" | sed -E 's:/*$::')"
  echo "[entrypoint] SUITECRM_SITE_URL=${suitecrm_site_url}"

  override_target_path="${PERSIST_CONFIG_DIR}/config_override.php"
  if [ ! -f "${override_target_path}" ]; then
    printf "<?php\n" > "${override_target_path}"
  fi
  if ! head -n 1 "${override_target_path}" | grep -q "^<\\?php"; then
    tmp_override="$(mktemp)"
    printf "<?php\n" > "${tmp_override}"
    cat "${override_target_path}" >> "${tmp_override}"
    mv "${tmp_override}" "${override_target_path}"
  fi

  override_marker_begin="// BEGIN SUITECRM_SITE_URL"
  override_marker_end="// END SUITECRM_SITE_URL"
  tmp_override="$(mktemp)"
  awk -v begin="${override_marker_begin}" -v end="${override_marker_end}" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "${override_target_path}" > "${tmp_override}"

  cat >> "${tmp_override}" <<EOF
${override_marker_begin}
\$sugar_config['site_url'] = '${suitecrm_site_url}';
if (!empty(\$_SERVER['HTTP_X_FORWARDED_PROTO']) && strtolower(\$_SERVER['HTTP_X_FORWARDED_PROTO']) === 'https') {
    \$_SERVER['HTTPS'] = 'on';
    \$_SERVER['SERVER_PORT'] = '443';
}
if (!empty(\$_SERVER['HTTP_X_FORWARDED_HOST'])) {
    \$_SERVER['HTTP_HOST'] = \$_SERVER['HTTP_X_FORWARDED_HOST'];
}
${override_marker_end}
EOF

  mv "${tmp_override}" "${override_target_path}"
  chown www-data:www-data "${override_target_path}" || true
  chmod 664 "${override_target_path}" || true
  echo "[entrypoint] site_url override applied: ${suitecrm_site_url}"
  echo "[entrypoint] proxy https support enabled: 1"
fi

if [ -s "${PERSIST_CONFIG_DIR}/config.php" ]; then
  ln -sfn "${PERSIST_CONFIG_DIR}/config.php" "${APP_ROOT}/config.php"
  resolved_config="$(readlink -f "${APP_ROOT}/config.php" 2>/dev/null || true)"
  if [ -z "${resolved_config}" ]; then
    resolved_config="${PERSIST_CONFIG_DIR}/config.php"
  fi
  echo "[entrypoint] config.php -> ${resolved_config} (symlink)"
else
  rm -f "${APP_ROOT}/config.php"
  echo "[entrypoint] config.php missing in ${PERSIST_CONFIG_DIR}; installer may run"
fi

if [ -f "${PERSIST_CONFIG_DIR}/config_override.php" ]; then
  ln -sfn "${PERSIST_CONFIG_DIR}/config_override.php" "${APP_ROOT}/config_override.php"
  resolved_override="$(readlink -f "${APP_ROOT}/config_override.php" 2>/dev/null || true)"
  if [ -z "${resolved_override}" ]; then
    resolved_override="${PERSIST_CONFIG_DIR}/config_override.php"
  fi
  echo "[entrypoint] config_override.php -> ${resolved_override} (symlink)"
else
  rm -f "${APP_ROOT}/config_override.php"
  echo "[entrypoint] config_override.php not present in ${PERSIST_CONFIG_DIR}"
fi

chown -R www-data:www-data "${APP_ROOT}/cache" "${APP_ROOT}/data" "${APP_ROOT}/upload"
chmod -R u+rwX,g+rwX "${APP_ROOT}/cache" "${APP_ROOT}/data" "${APP_ROOT}/upload"
chown -R www-data:www-data "${APP_ROOT}/custom"
chmod -R u+rwX,g+rwX "${APP_ROOT}/custom"

config_target="${PERSIST_CONFIG_DIR}/config.php"
override_target="${PERSIST_CONFIG_DIR}/config_override.php"

config_target_readable=0
config_target_writable=0
if [ -f "${config_target}" ]; then
  if su -s /bin/sh -c "test -r '${config_target}'" www-data; then
    config_target_readable=1
  fi
  if su -s /bin/sh -c "test -w '${config_target}'" www-data; then
    config_target_writable=1
  fi
fi

override_target_readable=0
override_target_writable=0
if [ -f "${override_target}" ]; then
  if su -s /bin/sh -c "test -r '${override_target}'" www-data; then
    override_target_readable=1
  fi
  if su -s /bin/sh -c "test -w '${override_target}'" www-data; then
    override_target_writable=1
  fi
fi

echo "CONFIG_TARGET_READABLE=${config_target_readable} CONFIG_TARGET_WRITABLE=${config_target_writable}"
echo "OVERRIDE_TARGET_READABLE=${override_target_readable} OVERRIDE_TARGET_WRITABLE=${override_target_writable}"

config_access_ok=1
if [ -f "${config_target}" ]; then
  if [ "${config_target_readable}" -ne 1 ] || [ "${config_target_writable}" -ne 1 ]; then
    config_access_ok=0
  fi
fi
if [ -f "${override_target}" ]; then
  if [ "${override_target_readable}" -ne 1 ] || [ "${override_target_writable}" -ne 1 ]; then
    config_access_ok=0
  fi
fi
if [ "${config_access_ok}" -ne 1 ]; then
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

SUITECRM_DISABLE_INSTALLER="${SUITECRM_DISABLE_INSTALLER:-1}"
installer_disable_reason=""
if [ "${SUITECRM_DISABLE_INSTALLER}" = "0" ]; then
  installer_disable_reason="disabled by env"
else
  if su -s /bin/sh www-data -c "test -r '${config_target}'"; then
    config_size_bytes="$(su -s /bin/sh www-data -c "wc -c < '${config_target}' 2>/dev/null | tr -d ' '")"
    case "${config_size_bytes}" in
      ''|*[!0-9]*) config_size_bytes="0" ;;
    esac
    if [ "${config_size_bytes}" -le 2048 ]; then
      installer_disable_reason="small config"
    else
      if su -s /bin/sh www-data -c "grep -q -E \"installer_locked.*(true|1)\" '${config_target}'"; then
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
