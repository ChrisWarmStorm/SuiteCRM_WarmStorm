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

get_env_value() {
  local value=""
  for key in "$@"; do
    value="$(printenv "$key" 2>/dev/null || true)"
    if [ -n "${value}" ]; then
      printf '%s' "${value}"
      return 0
    fi
  done
  return 1
}

mask_value() {
  local value="$1"
  local length="${#value}"
  if [ -z "${value}" ]; then
    printf 'unknown'
    return 0
  fi
  if [ "${length}" -le 4 ]; then
    printf '****'
    return 0
  fi
  printf '%s****%s' "${value:0:2}" "${value: -2}"
}

php_escape() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\'/\\\'}"
  printf '%s' "${value}"
}

hash_value() {
  php -r 'echo hash("sha1", $argv[1]);' "$1"
}

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

if [ ! -f /etc/apache2/conf-available/servername.conf ]; then
  echo "ServerName localhost" > /etc/apache2/conf-available/servername.conf
fi
if a2enconf servername >/dev/null 2>&1; then
  echo "[entrypoint] apache-servername enabled: 1"
else
  echo "[entrypoint] apache-servername enabled: 0"
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
echo "[entrypoint] PERSIST_CONFIG_DIR=${PERSIST_CONFIG_DIR}"

if [ -f "${APP_ROOT}/config.php" ] && [ ! -L "${APP_ROOT}/config.php" ]; then
  mv "${APP_ROOT}/config.php" "${PERSIST_CONFIG_DIR}/config.php.bak.$(date +%s)"
fi

if [ -f "${APP_ROOT}/config_override.php" ] && [ ! -L "${APP_ROOT}/config_override.php" ]; then
  mv "${APP_ROOT}/config_override.php" "${PERSIST_CONFIG_DIR}/config_override.php.bak.$(date +%s)"
fi

config_size_bytes="0"
config_zero_byte=0
if [ -f "${PERSIST_CONFIG_DIR}/config.php" ]; then
  config_size_bytes="$(wc -c < "${PERSIST_CONFIG_DIR}/config.php" 2>/dev/null | tr -d ' ')"
  case "${config_size_bytes}" in
    ''|*[!0-9]*) config_size_bytes="0" ;;
  esac
  if [ "${config_size_bytes}" = "0" ]; then
    config_zero_byte=1
  fi
fi

if [ -f "${PERSIST_CONFIG_DIR}/config_override.php" ] && [ ! -s "${PERSIST_CONFIG_DIR}/config_override.php" ] && [ -f "${CONFIG_TEMPLATE_PATH}" ]; then
  if ! su -s /bin/sh www-data -c "cp '${CONFIG_TEMPLATE_PATH}' '${PERSIST_CONFIG_DIR}/config_override.php'"; then
    echo "[entrypoint] Warning: failed to seed config_override.php from ${CONFIG_TEMPLATE_PATH}"
  fi
fi

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

public_url_raw="${PUBLIC_URL:-}"
if [ -n "${public_url_raw}" ]; then
  public_url="$(printf '%s' "${public_url_raw}" | sed -E 's:/*$::')"
  public_url_escaped="$(php_escape "${public_url}")"
  echo "[entrypoint] PUBLIC_URL=${public_url}"

  public_host="$(php -r '
    $url = $argv[1] ?? "";
    $parts = parse_url($url);
    if (!is_array($parts) || empty($parts["host"])) {
      exit(2);
    }
    echo $parts["host"];
  ' "${public_url}" || true)"

  if [ -z "${public_host}" ]; then
    echo "[entrypoint] FATAL: PUBLIC_URL is invalid or missing host"
    exit 1
  fi

  public_host_escaped="$(php_escape "${public_host}")"

  override_marker_begin="// BEGIN SUITECRM_PUBLIC_URL"
  override_marker_end="// END SUITECRM_PUBLIC_URL"
  tmp_override="$(mktemp)"
  awk -v begin="${override_marker_begin}" -v end="${override_marker_end}" '
    $0 == begin {skip=1; next}
    $0 == end {skip=0; next}
    !skip {print}
  ' "${override_target_path}" > "${tmp_override}"

  cat >> "${tmp_override}" <<EOF
${override_marker_begin}
\$sugar_config['site_url'] = '${public_url_escaped}';
\$sugar_config['host_name'] = '${public_host_escaped}';
if (!isset(\$sugar_config['trusted_hosts']) || !is_array(\$sugar_config['trusted_hosts'])) {
    \$sugar_config['trusted_hosts'] = array();
}
if (!in_array('${public_host_escaped}', \$sugar_config['trusted_hosts'], true)) {
    \$sugar_config['trusted_hosts'][] = '${public_host_escaped}';
}
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
  echo "[entrypoint] site_url_override_set=1"
  echo "[entrypoint] proxy_https_support=1"
fi

db_source=""
db_config_type="mysqli"
db_manager="MysqliManager"
db_host="${DB_HOST:-}"
db_port="${DB_PORT:-}"
db_name="${DB_NAME:-}"
db_user="${DB_USER:-}"
db_password="${DB_PASSWORD:-}"
db_unique_key=""
db_allow_schema_init="${DB_ALLOW_SCHEMA_INIT:-0}"
db_require_persistent="${DB_REQUIRE_PERSISTENT:-1}"
db_fingerprint_table="${DB_FINGERPRINT_TABLE:-users}"
db_fingerprint_table="$(printf '%s' "${db_fingerprint_table}" | tr ',' ' ' | awk '{print $1}')"
if [ -z "${db_fingerprint_table}" ]; then
  db_fingerprint_table="users"
fi
db_url_scheme=""
db_url_host=""
db_url_port=""
db_url_name=""
db_url_user=""
db_url_pass=""

if [ -n "${DATABASE_URL:-}" ]; then
  db_url_output=""
  db_url_error="$(mktemp)"
  set +e
  db_url_output="$(php -r '
  $url = getenv("DATABASE_URL");
  if ($url === false || $url === "") { fwrite(STDERR, "DATABASE_URL missing
"); exit(2); }
  $parts = parse_url($url);
  if (!is_array($parts) || empty($parts["scheme"]) || empty($parts["host"])) {
      fwrite(STDERR, "DATABASE_URL invalid
");
      exit(3);
  }
  $scheme = strtolower($parts["scheme"] ?? "");
  $host = $parts["host"] ?? "";
  $port = $parts["port"] ?? "";
  $user = isset($parts["user"]) ? urldecode($parts["user"]) : "";
  $pass = isset($parts["pass"]) ? urldecode($parts["pass"]) : "";
  $path = $parts["path"] ?? "";
  $db = ltrim($path, "/");
  echo "DB_URL_SCHEME={$scheme}
";
  echo "DB_URL_HOST={$host}
";
  echo "DB_URL_PORT={$port}
";
  echo "DB_URL_NAME={$db}
";
  echo "DB_URL_USER={$user}
";
  echo "DB_URL_PASS={$pass}
";
  ' 2>"${db_url_error}")"
  db_url_status=$?
  set -e
  if [ "${db_url_status}" -ne 0 ]; then
    echo "[entrypoint] FATAL: failed to parse DATABASE_URL"
    cat "${db_url_error}" || true
    rm -f "${db_url_error}"
    exit 1
  fi
  rm -f "${db_url_error}"

  while IFS='=' read -r key value; do
    case "${key}" in
      DB_URL_SCHEME) db_url_scheme="${value}" ;;
      DB_URL_HOST) db_url_host="${value}" ;;
      DB_URL_PORT) db_url_port="${value}" ;;
      DB_URL_NAME) db_url_name="${value}" ;;
      DB_URL_USER) db_url_user="${value}" ;;
      DB_URL_PASS) db_url_pass="${value}" ;;
    esac
  done <<< "${db_url_output}"
fi

db_url_supported=1
if [ -n "${db_url_scheme}" ]; then
  case "${db_url_scheme}" in
    mysql|mariadb)
      db_url_supported=1
      ;;
    *)
      db_url_supported=0
      ;;
  esac
fi

if [ "${db_url_supported}" -ne 1 ]; then
  if [ -z "${db_host}" ] || [ -z "${db_name}" ] || [ -z "${db_user}" ] || [ -z "${db_password}" ]; then
    echo "[entrypoint] FATAL: unsupported DATABASE_URL scheme (only mysql/mariadb are supported)"
    exit 1
  fi
fi

if [ "${db_url_supported}" -eq 1 ] && [ -z "${db_host}" ] && [ -n "${db_url_host}" ]; then
  db_host="${db_url_host}"
  db_source="DATABASE_URL"
fi
if [ "${db_url_supported}" -eq 1 ] && [ -z "${db_port}" ] && [ -n "${db_url_port}" ]; then
  db_port="${db_url_port}"
  db_source="DATABASE_URL"
fi
if [ "${db_url_supported}" -eq 1 ] && [ -z "${db_name}" ] && [ -n "${db_url_name}" ]; then
  db_name="${db_url_name}"
  db_source="DATABASE_URL"
fi
if [ "${db_url_supported}" -eq 1 ] && [ -z "${db_user}" ] && [ -n "${db_url_user}" ]; then
  db_user="${db_url_user}"
  db_source="DATABASE_URL"
fi
if [ "${db_url_supported}" -eq 1 ] && [ -z "${db_password}" ] && [ -n "${db_url_pass}" ]; then
  db_password="${db_url_pass}"
  db_source="DATABASE_URL"
fi

if [ -z "${db_source}" ]; then
  db_source="DB_VARS"
fi

if [ -z "${db_port}" ]; then
  db_port="3306"
fi

if [ -z "${db_host}" ] || [ -z "${db_name}" ] || [ -z "${db_user}" ] || [ -z "${db_password}" ]; then
  echo "[entrypoint] FATAL: database env vars missing. Set DB_HOST, DB_NAME, DB_USER, DB_PASSWORD (and DB_PORT)."
  exit 1
fi

if [ "${db_require_persistent}" != "0" ]; then
  case "${db_host}" in
    localhost|127.0.0.1|::1)
      echo "[entrypoint] FATAL: DB_HOST points to local host (${db_host}); refusing to use ephemeral DB."
      exit 1
      ;;
  esac
fi

echo "[entrypoint] DB_HOST=${db_host}"
echo "[entrypoint] DB_NAME=${db_name}"
echo "[entrypoint] DB_REQUIRE_PERSISTENT=${db_require_persistent}"
echo "[entrypoint] DB_ALLOW_SCHEMA_INIT=${db_allow_schema_init}"
masked_host="$(mask_value "${db_host}")"
masked_user="$(mask_value "${db_user}")"
echo "[entrypoint] DB_TARGET=mysql host=${masked_host} port=${db_port} db=${db_name} user=${masked_user} source=${db_source}"

db_check_script="$(mktemp)"
cat > "${db_check_script}" <<'PHP'
<?php
$host = getenv('SUITECRM_DB_HOST') ?: '';
$port = getenv('SUITECRM_DB_PORT') ?: '';
$db = getenv('SUITECRM_DB_NAME') ?: '';
$user = getenv('SUITECRM_DB_USER') ?: '';
$pass = getenv('SUITECRM_DB_PASSWORD') ?: '';
$fingerprintTable = getenv('SUITECRM_DB_FINGERPRINT_TABLE') ?: 'users';
$coreTables = ['users', 'accounts', 'email_addresses', 'config'];

$tableCount = 0;
$coreMatchCount = 0;
$tablesExist = 0;
$usersCount = 0;
$serverVersion = '';
$uniqueKey = '';

$clean = static function ($value) {
    return preg_replace('/[
]+/', '', (string)$value);
};

$sanitizeTable = static function ($value) {
    $value = preg_replace('/[^A-Za-z0-9_]/', '', (string)$value);
    return $value !== '' ? $value : 'users';
};

$fingerprintTable = $sanitizeTable($fingerprintTable);

try {
    $mysqli = @new mysqli($host, $user, $pass, $db, (int)$port);
    if ($mysqli->connect_errno) {
        fwrite(STDERR, "mysql_connect_failed={$mysqli->connect_error}
");
        exit(2);
    }
    $dbEsc = $mysqli->real_escape_string($db);
    $inList = "'" . implode("','", $coreTables) . "'";

    $res = $mysqli->query("SELECT COUNT(*) AS c FROM information_schema.tables WHERE table_schema='{$dbEsc}' AND table_name IN ({$inList})");
    if ($res && ($row = $res->fetch_assoc())) {
        $coreMatchCount = (int)$row['c'];
    }
    $tablesExist = $coreMatchCount > 0 ? 1 : 0;

    $res = $mysqli->query("SELECT COUNT(*) AS c FROM information_schema.tables WHERE table_schema='{$dbEsc}'");
    if ($res && ($row = $res->fetch_assoc())) {
        $tableCount = (int)$row['c'];
    }

    $tableEsc = $mysqli->real_escape_string($fingerprintTable);
    $res = $mysqli->query("SELECT COUNT(*) AS c FROM information_schema.tables WHERE table_schema='{$dbEsc}' AND table_name='{$tableEsc}'");
    if ($res && ($row = $res->fetch_assoc()) && (int)$row['c'] > 0) {
        $resUsers = $mysqli->query("SELECT COUNT(*) AS c FROM `{$fingerprintTable}`");
        if ($resUsers && ($rowUsers = $resUsers->fetch_assoc())) {
            $usersCount = (int)$rowUsers['c'];
        }
    }

    $serverVersion = $clean($mysqli->server_info ?? '');

    if ($tablesExist === 1) {
        $res = $mysqli->query("SELECT value FROM config WHERE category='system' AND name='unique_key' LIMIT 1");
        if ($res && ($row = $res->fetch_assoc())) {
            $uniqueKey = (string)$row['value'];
        }
    }

    $mysqli->close();
} catch (Throwable $e) {
    fwrite(STDERR, "db_check_failed=".$e->getMessage()."
");
    exit(4);
}

echo "DB_TABLES_EXIST={$tablesExist}
";
echo "DB_CORE_TABLE_COUNT={$tableCount}
";
echo "DB_USERS_COUNT={$usersCount}
";
echo "DB_SERVER_VERSION={$serverVersion}
";
if ($uniqueKey !== '') {
    echo "DB_UNIQUE_KEY={$uniqueKey}
";
}
PHP

db_check_error="$(mktemp)"
set +e
db_check_output="$(env SUITECRM_DB_HOST="${db_host}" SUITECRM_DB_PORT="${db_port}" SUITECRM_DB_NAME="${db_name}" SUITECRM_DB_USER="${db_user}" SUITECRM_DB_PASSWORD="${db_password}" SUITECRM_DB_FINGERPRINT_TABLE="${db_fingerprint_table}" php "${db_check_script}" 2>"${db_check_error}")"
db_check_status=$?
set -e
rm -f "${db_check_script}"
if [ "${db_check_status}" -ne 0 ]; then
  echo "[entrypoint] FATAL: database connectivity/schema check failed"
  cat "${db_check_error}" || true
  rm -f "${db_check_error}"
  exit 1
fi
rm -f "${db_check_error}"

db_tables_exist="0"
db_core_table_count="0"
db_users_count="0"
db_server_version=""
while IFS='=' read -r key value; do
  case "${key}" in
    DB_TABLES_EXIST) db_tables_exist="${value}" ;;
    DB_CORE_TABLE_COUNT) db_core_table_count="${value}" ;;
    DB_USERS_COUNT) db_users_count="${value}" ;;
    DB_SERVER_VERSION) db_server_version="${value}" ;;
    DB_UNIQUE_KEY) db_unique_key="${value}" ;;
  esac
done <<< "${db_check_output}"

if [ -z "${db_server_version}" ]; then
  db_server_version="unknown"
fi

echo "[entrypoint] DB_TABLES_EXIST=${db_tables_exist}"
echo "[entrypoint] DB_CORE_TABLE_COUNT=${db_core_table_count}"
echo "[entrypoint] DB_USERS_COUNT=${db_users_count}"
echo "[entrypoint] DB_SCHEMA_MUTATION=0"

fingerprint_input="mysql:${db_server_version}|db:${db_name}|tables:${db_core_table_count}|users:${db_users_count}"
db_fingerprint="$(hash_value "${fingerprint_input}")"
echo "[entrypoint] DB_FINGERPRINT=${db_fingerprint}"

db_fingerprint_file="${PERSIST_CONFIG_DIR}/last_db_fingerprint.txt"
prev_db_fingerprint=""
if [ -f "${db_fingerprint_file}" ]; then
  while IFS='=' read -r key value; do
    case "${key}" in
    DB_FINGERPRINT) prev_db_fingerprint="${value}" ;;
    esac
  done < "${db_fingerprint_file}"
fi

if [ -n "${prev_db_fingerprint}" ] && [ "${db_tables_exist}" != "1" ] && [ "${db_allow_schema_init}" != "1" ]; then
  echo "[entrypoint] FATAL: DB appears empty but previously had tables. This indicates non-persistent DB or wrong DB_* vars."
  exit 1
fi

if ! cat > "${db_fingerprint_file}" <<EOF
DB_FINGERPRINT=${db_fingerprint}
DB_TABLES_EXIST=${db_tables_exist}
DB_CORE_TABLE_COUNT=${db_core_table_count}
DB_USERS_COUNT=${db_users_count}
DB_SERVER_VERSION=${db_server_version}
DB_NAME=${db_name}
EOF
then
  echo "[entrypoint] Warning: failed to write ${db_fingerprint_file}"
fi

if [ "${db_tables_exist}" != "1" ] && [ "${db_allow_schema_init}" != "1" ]; then
  echo "[entrypoint] Refusing to run installer because DB is empty and DB_ALLOW_SCHEMA_INIT=0"
  exit 1
fi

db_host_escaped="$(php_escape "${db_host}")"
db_port_escaped="$(php_escape "${db_port}")"
db_name_escaped="$(php_escape "${db_name}")"
db_user_escaped="$(php_escape "${db_user}")"
db_password_escaped="$(php_escape "${db_password}")"
db_config_type_escaped="$(php_escape "${db_config_type}")"
db_manager_escaped="$(php_escape "${db_manager}")"

db_override_begin="// BEGIN SUITECRM_DB_CONFIG"
db_override_end="// END SUITECRM_DB_CONFIG"
tmp_override="$(mktemp)"
awk -v begin="${db_override_begin}" -v end="${db_override_end}" '
  $0 == begin {skip=1; next}
  $0 == end {skip=0; next}
  !skip {print}
' "${override_target_path}" > "${tmp_override}"

cat >> "${tmp_override}" <<EOF
${db_override_begin}
\$sugar_config['dbconfig']['db_host_name'] = '${db_host_escaped}';
\$sugar_config['dbconfig']['db_port'] = '${db_port_escaped}';
\$sugar_config['dbconfig']['db_name'] = '${db_name_escaped}';
\$sugar_config['dbconfig']['db_user_name'] = '${db_user_escaped}';
\$sugar_config['dbconfig']['db_password'] = '${db_password_escaped}';
\$sugar_config['dbconfig']['db_type'] = '${db_config_type_escaped}';
EOF

if [ -n "${db_manager}" ]; then
  cat >> "${tmp_override}" <<EOF
\$sugar_config['dbconfig']['db_manager'] = '${db_manager_escaped}';
EOF
fi

cat >> "${tmp_override}" <<EOF
${db_override_end}
EOF

mv "${tmp_override}" "${override_target_path}"
chown www-data:www-data "${override_target_path}" || true
chmod 664 "${override_target_path}" || true
echo "[entrypoint] db override applied: 1"

config_regenerated=0
config_regen_reason=""
config_target_path="${PERSIST_CONFIG_DIR}/config.php"
site_url_for_config="${PUBLIC_URL:-${SUITECRM_SITE_URL:-${APP_URL:-}}}"
if [ -n "${site_url_for_config}" ]; then
  site_url_for_config="$(printf '%s' "${site_url_for_config}" | sed -E 's:/*$::')"
fi

if [ "${db_tables_exist}" = "1" ]; then
  if [ ! -s "${config_target_path}" ]; then
    config_regenerated=1
    config_regen_reason="db_tables_exist"
    config_tmp="$(mktemp)"
    config_gen_error="$(mktemp)"
    set +e
    env SUITECRM_DB_TYPE="${db_config_type}" \
        SUITECRM_DB_MANAGER="${db_manager}" \
        SUITECRM_DB_HOST="${db_host}" \
        SUITECRM_DB_PORT="${db_port}" \
        SUITECRM_DB_NAME="${db_name}" \
        SUITECRM_DB_USER="${db_user}" \
        SUITECRM_DB_PASSWORD="${db_password}" \
        SUITECRM_SITE_URL="${site_url_for_config}" \
        SUITECRM_UNIQUE_KEY="${db_unique_key}" \
        SUITECRM_CONFIG_TARGET="${config_tmp}" \
        php <<'PHP' 2>"${config_gen_error}"
<?php
define('sugarEntry', true);
require_once 'include/utils.php';

$config = get_sugar_config_defaults();
$config['dbconfig'] = $config['dbconfig'] ?? [];
$config['dbconfigoption'] = $config['dbconfigoption'] ?? [];

$config['dbconfig']['db_host_name'] = getenv('SUITECRM_DB_HOST');
$config['dbconfig']['db_port'] = getenv('SUITECRM_DB_PORT');
$config['dbconfig']['db_name'] = getenv('SUITECRM_DB_NAME');
$config['dbconfig']['db_user_name'] = getenv('SUITECRM_DB_USER');
$config['dbconfig']['db_password'] = getenv('SUITECRM_DB_PASSWORD');
$config['dbconfig']['db_type'] = getenv('SUITECRM_DB_TYPE');

$dbManager = getenv('SUITECRM_DB_MANAGER');
if ($dbManager !== false && $dbManager !== '') {
    $config['dbconfig']['db_manager'] = $dbManager;
}

$siteUrl = getenv('SUITECRM_SITE_URL');
if ($siteUrl !== false && $siteUrl !== '') {
    $config['site_url'] = rtrim($siteUrl, '/');
}

$uniqueKey = getenv('SUITECRM_UNIQUE_KEY');
if ($uniqueKey !== false && $uniqueKey !== '') {
    $config['unique_key'] = $uniqueKey;
}

$config['installer_locked'] = true;
$config['cache_dir'] = $config['cache_dir'] ?? 'cache/';
$config['upload_dir'] = $config['upload_dir'] ?? 'upload/';
$config['tmp_dir'] = $config['tmp_dir'] ?? 'cache/tmp/';
$config['session_dir'] = $config['session_dir'] ?? 'cache/sessions/';
$config['log_dir'] = $config['log_dir'] ?? 'log/';
$config['log_file'] = $config['log_file'] ?? 'suitecrm.log';

$target = getenv('SUITECRM_CONFIG_TARGET');
if ($target === false || $target === '') {
    fwrite(STDERR, "missing config target\n");
    exit(2);
}

$contents = "<?php\n" .
    '// created: ' . gmdate('Y-m-d H:i:s') . "\n" .
    '$sugar_config = ' . var_export($config, true) . ";\n";
if (file_put_contents($target, $contents) === false) {
    fwrite(STDERR, "failed to write config\n");
    exit(3);
}
PHP
    config_gen_status=$?
    set -e
    if [ "${config_gen_status}" -ne 0 ]; then
      echo "[entrypoint] FATAL: failed to generate config.php"
      cat "${config_gen_error}" || true
      rm -f "${config_tmp}" "${config_gen_error}"
      exit 1
    fi
    rm -f "${config_gen_error}"
    mv "${config_tmp}" "${config_target_path}"
    chown www-data:www-data "${config_target_path}" || true
    chmod 664 "${config_target_path}" || true
  fi
fi

if [ -f "${PERSIST_CONFIG_DIR}/config.php" ]; then
  config_current_size="$(wc -c < "${PERSIST_CONFIG_DIR}/config.php" 2>/dev/null | tr -d ' ')"
  case "${config_current_size}" in
    ''|*[!0-9]*) config_current_size="0" ;;
  esac
  if [ "${config_current_size}" = "0" ]; then
    echo "[entrypoint] zero-byte persisted config.php detected; removing"
    rm -f "${PERSIST_CONFIG_DIR}/config.php"
  fi
fi

if [ "${config_regenerated}" -eq 1 ]; then
  echo "[entrypoint] CONFIG_REGENERATED=1 reason=${config_regen_reason}"
fi

if [ -f "${PERSIST_CONFIG_DIR}/config.php" ]; then
  config_size_bytes="$(wc -c < "${PERSIST_CONFIG_DIR}/config.php" 2>/dev/null | tr -d ' ')"
  case "${config_size_bytes}" in
    ''|*[!0-9]*) config_size_bytes="0" ;;
  esac
fi
echo "[entrypoint] CONFIG_TARGET_SIZE=${config_size_bytes}"

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

if [ -s "${PERSIST_CONFIG_DIR}/config_override.php" ]; then
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

installer_disabled=0
installer_disable_reason=""
if [ "${db_tables_exist}" = "1" ]; then
  if [ -d "${APP_ROOT}/install" ] && [ ! -e "${APP_ROOT}/install.disabled" ]; then
    mv "${APP_ROOT}/install" "${APP_ROOT}/install.disabled"
    su -s /bin/sh www-data -c "touch '${PERSIST_CONFIG_DIR}/install.disabled.marker'" || true
    echo "[entrypoint] Installer disabled due to existing DB schema"
  fi
  installer_disabled=1
  installer_disable_reason="db_tables_exist"
else
  if [ "${db_allow_schema_init}" = "1" ]; then
    installer_disabled=0
    installer_disable_reason="db_empty_allow_init"
  else
    installer_disabled=1
    installer_disable_reason="db_empty_disallowed"
  fi
fi

if [ "${installer_disabled}" -eq 1 ]; then
  echo "[entrypoint] INSTALLER_DISABLED=1 reason=${installer_disable_reason}"
else
  echo "[entrypoint] INSTALLER_DISABLED=0 reason=${installer_disable_reason}"
  if [ -n "${installer_disable_reason}" ]; then
    echo "[entrypoint] Installer not disabled (reason: ${installer_disable_reason})"
  fi
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

if [ "${SMOKE_CHECK:-0}" = "1" ]; then
  echo "[entrypoint] SMOKE_CHECK=1 exiting before exec"
  exit 0
fi

exec "$@"
