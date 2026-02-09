#!/usr/bin/env bash
set -euo pipefail

db_source="DB_VARS"
db_host="${DB_HOST:-}"
db_port="${DB_PORT:-}"
db_name="${DB_NAME:-}"
db_user="${DB_USER:-}"
db_password="${DB_PASSWORD:-}"
db_fingerprint_table="${DB_FINGERPRINT_TABLE:-users}"

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
  if ($url === false || $url === "") { fwrite(STDERR, "DATABASE_URL missing\n"); exit(2); }
  $parts = parse_url($url);
  if (!is_array($parts) || empty($parts["scheme"]) || empty($parts["host"])) {
      fwrite(STDERR, "DATABASE_URL invalid\n");
      exit(3);
  }
  $scheme = strtolower($parts["scheme"] ?? "");
  $host = $parts["host"] ?? "";
  $port = $parts["port"] ?? "";
  $user = isset($parts["user"]) ? urldecode($parts["user"]) : "";
  $pass = isset($parts["pass"]) ? urldecode($parts["pass"]) : "";
  $path = $parts["path"] ?? "";
  $db = ltrim($path, "/");
  echo "DB_URL_SCHEME={$scheme}\n";
  echo "DB_URL_HOST={$host}\n";
  echo "DB_URL_PORT={$port}\n";
  echo "DB_URL_NAME={$db}\n";
  echo "DB_URL_USER={$user}\n";
  echo "DB_URL_PASS={$pass}\n";
  ' 2>"${db_url_error}")"
  db_url_status=$?
  set -e
  if [ "${db_url_status}" -ne 0 ]; then
    echo "failed to parse DATABASE_URL"
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

  case "${db_url_scheme}" in
    mysql|mariadb)
      ;;
    *)
      echo "unsupported DATABASE_URL scheme (only mysql/mariadb are supported)"
      exit 1
      ;;
  esac
fi

if [ -z "${db_host}" ] && [ -n "${db_url_host}" ]; then
  db_host="${db_url_host}"
  db_source="DATABASE_URL"
fi
if [ -z "${db_port}" ] && [ -n "${db_url_port}" ]; then
  db_port="${db_url_port}"
  db_source="DATABASE_URL"
fi
if [ -z "${db_name}" ] && [ -n "${db_url_name}" ]; then
  db_name="${db_url_name}"
  db_source="DATABASE_URL"
fi
if [ -z "${db_user}" ] && [ -n "${db_url_user}" ]; then
  db_user="${db_url_user}"
  db_source="DATABASE_URL"
fi
if [ -z "${db_password}" ] && [ -n "${db_url_pass}" ]; then
  db_password="${db_url_pass}"
  db_source="DATABASE_URL"
fi

if [ -z "${db_port}" ]; then
  db_port="3306"
fi

echo "db_env_source=${db_source}"
echo "db_host=${db_host} db_name=${db_name} db_port=${db_port}"

if [ -z "${db_host}" ] || [ -z "${db_name}" ] || [ -z "${db_user}" ] || [ -z "${db_password}" ]; then
  echo "missing DB_* env vars (DB_HOST, DB_NAME, DB_USER, DB_PASSWORD)"
  exit 1
fi

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

$sanitizeTable = static function ($value) {
    $value = preg_replace('/[^A-Za-z0-9_]/', '', (string)$value);
    return $value !== '' ? $value : 'users';
};

$fingerprintTable = $sanitizeTable($fingerprintTable);

try {
    $mysqli = @new mysqli($host, $user, $pass, $db, (int)$port);
    if ($mysqli->connect_errno) {
        fwrite(STDERR, "mysql_connect_failed={$mysqli->connect_error}\n");
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

    $mysqli->close();
} catch (Throwable $e) {
    fwrite(STDERR, "db_check_failed=".$e->getMessage()."\n");
    exit(4);
}

echo "DB_TABLES_EXIST={$tablesExist}\n";
echo "DB_CORE_TABLE_COUNT={$tableCount}\n";
echo "DB_USERS_COUNT={$usersCount}\n";
PHP

db_check_error="$(mktemp)"
set +e
db_check_output="$(env SUITECRM_DB_HOST="${db_host}" SUITECRM_DB_PORT="${db_port}" SUITECRM_DB_NAME="${db_name}" SUITECRM_DB_USER="${db_user}" SUITECRM_DB_PASSWORD="${db_password}" SUITECRM_DB_FINGERPRINT_TABLE="${db_fingerprint_table}" php "${db_check_script}" 2>"${db_check_error}")"
db_check_status=$?
set -e
rm -f "${db_check_script}"
if [ "${db_check_status}" -ne 0 ]; then
  echo "db check failed"
  cat "${db_check_error}" || true
  rm -f "${db_check_error}"
  exit 1
fi
rm -f "${db_check_error}"

db_tables_exist="0"
db_core_table_count="0"
db_users_count="0"
while IFS='=' read -r key value; do
  case "${key}" in
    DB_TABLES_EXIST) db_tables_exist="${value}" ;;
    DB_CORE_TABLE_COUNT) db_core_table_count="${value}" ;;
    DB_USERS_COUNT) db_users_count="${value}" ;;
  esac
done <<< "${db_check_output}"

echo "DB_TABLES_EXIST=${db_tables_exist}"
echo "DB_CORE_TABLE_COUNT=${db_core_table_count}"
echo "DB_USERS_COUNT=${db_users_count}"

if [ "${EXPECT_DB_TABLES_EXIST:-}" = "1" ] && [ "${db_tables_exist}" != "1" ]; then
  echo "EXPECT_DB_TABLES_EXIST=1 but DB_TABLES_EXIST=${db_tables_exist}"
  exit 1
fi
if [ "${EXPECT_DB_TABLES_EXIST:-}" = "0" ] && [ "${db_tables_exist}" != "0" ]; then
  echo "EXPECT_DB_TABLES_EXIST=0 but DB_TABLES_EXIST=${db_tables_exist}"
  exit 1
fi

echo "smoke test ok"
