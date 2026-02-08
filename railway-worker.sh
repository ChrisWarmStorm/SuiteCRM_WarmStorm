#!/usr/bin/env bash
set -u

APP_DIR="${APP_DIR:-/var/www/html}"
SLEEP_SECONDS="${SLEEP_SECONDS:-60}"
RUN_ONCE="${RUN_ONCE:-0}"

if [ ! -d "${APP_DIR}" ]; then
  echo "[worker] APP_DIR not found: ${APP_DIR}"
  exit 1
fi
cd "${APP_DIR}"

CRON_PATH=""
for candidate in "${APP_DIR}/public/legacy/cron.php" "${APP_DIR}/legacy/cron.php" "${APP_DIR}/cron.php"; do
  if [ -f "${candidate}" ]; then
    CRON_PATH="${candidate}"
    break
  fi
done

if [ -z "${CRON_PATH}" ]; then
  echo "[worker] cron.php not found. Checked:"
  echo "[worker] ${APP_DIR}/public/legacy/cron.php"
  echo "[worker] ${APP_DIR}/legacy/cron.php"
  echo "[worker] ${APP_DIR}/cron.php"
  exit 1
fi

echo "[worker] Cron path selected: ${CRON_PATH}"

if [ -n "${WORKER_INSTANCE_ID:-}" ]; then
  echo "[worker] Warning: WORKER_INSTANCE_ID=${WORKER_INSTANCE_ID} - ensure scale=1"
fi
if [ -n "${RAILWAY_REPLICA_ID:-}" ]; then
  echo "[worker] Warning: RAILWAY_REPLICA_ID=${RAILWAY_REPLICA_ID} - ensure scale=1"
fi
if [ -n "${RAILWAY_REPLICA_INDEX:-}" ]; then
  echo "[worker] Warning: RAILWAY_REPLICA_INDEX=${RAILWAY_REPLICA_INDEX} - ensure scale=1"
fi

DB_HOST="${DB_HOST:-${MYSQLHOST:-${MARIADB_HOST:-${MYSQL_HOST:-}}}}"
DB_PORT="${DB_PORT:-${MYSQLPORT:-${MARIADB_PORT:-${MYSQL_PORT:-}}}}"
DB_NAME="${DB_NAME:-${MYSQLDATABASE:-${MARIADB_DATABASE:-${MYSQL_DATABASE:-}}}}"
DB_USER="${DB_USER:-${MYSQLUSER:-${MARIADB_USER:-${MYSQL_USER:-}}}}"
DB_PASSWORD="${DB_PASSWORD:-${MYSQLPASSWORD:-${MARIADB_PASSWORD:-${MYSQL_PASSWORD:-}}}}"

export DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD

acquire_db_lock() {
  php -r '
$host = getenv("DB_HOST");
$port = getenv("DB_PORT") ?: "3306";
$name = getenv("DB_NAME");
$user = getenv("DB_USER");
$pass = getenv("DB_PASSWORD");
if (!$host || !$name || !$user) { fwrite(STDERR, "missing db env\n"); exit(5); }
$mysqli = new mysqli($host, $user, $pass, $name, (int)$port);
if ($mysqli->connect_errno) { fwrite(STDERR, "connect failed\n"); exit(3); }
$res = $mysqli->query("SELECT GET_LOCK('suitecrm_cron_lock', 0) AS l");
if (!$res) { fwrite(STDERR, "lock query failed\n"); exit(4); }
$row = $res->fetch_assoc();
$acquired = isset($row["l"]) && (int)$row["l"] === 1;
exit($acquired ? 0 : 2);
'
}

release_db_lock() {
  php -r '
$host = getenv("DB_HOST");
$port = getenv("DB_PORT") ?: "3306";
$name = getenv("DB_NAME");
$user = getenv("DB_USER");
$pass = getenv("DB_PASSWORD");
if (!$host || !$name || !$user) { exit(5); }
$mysqli = new mysqli($host, $user, $pass, $name, (int)$port);
if ($mysqli->connect_errno) { exit(3); }
$mysqli->query("SELECT RELEASE_LOCK('suitecrm_cron_lock')");
exit(0);
'
}

FAIL_COUNT=0

while true; do
  start="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "[worker] ${start} starting scheduler"
  echo "[worker] ${start} Cron path selected: ${CRON_PATH}"

  lock_acquired=0
  if [ "${ENABLE_CRON_DB_LOCK:-0}" = "1" ]; then
    if [ -n "${DB_HOST}" ] && [ -n "${DB_NAME}" ] && [ -n "${DB_USER}" ]; then
      lock_output="$(acquire_db_lock 2>&1)"
      lock_status=$?
      if [ "${DEBUG_DB_LOCK:-0}" = "1" ] && [ -n "${lock_output}" ]; then
        echo "[worker] ${start} db lock output: ${lock_output}"
      fi
      if [ "${lock_status}" -ne 0 ] && [ "${lock_status}" -ne 2 ]; then
        if [ -n "${lock_output}" ]; then
          short_line="$(printf '%s' "${lock_output}" | head -n1)"
          echo "[worker] ${start} db lock error: exit=${lock_status} msg=${short_line}"
        else
          echo "[worker] ${start} db lock error: exit=${lock_status}"
        fi
      fi
      if [ "${lock_status}" -eq 0 ]; then
        lock_acquired=1
      elif [ "${lock_status}" -eq 2 ]; then
        echo "[worker] ${start} db lock not acquired, skipping cycle"
        sleep "${SLEEP_SECONDS}"
        if [ "${RUN_ONCE}" = "1" ]; then
          exit 0
        fi
        continue
      else
        echo "[worker] ${start} db lock error, skipping cycle"
        sleep "${SLEEP_SECONDS}"
        if [ "${RUN_ONCE}" = "1" ]; then
          exit 1
        fi
        continue
      fi
    else
      echo "[worker] ${start} db lock enabled but DB env missing, skipping cycle"
      sleep "${SLEEP_SECONDS}"
      if [ "${RUN_ONCE}" = "1" ]; then
        exit 1
      fi
      continue
    fi
  fi

  php -f "${CRON_PATH}"
  exit_code=$?

  if [ "${lock_acquired}" -eq 1 ]; then
    release_output="$(release_db_lock 2>&1)"
    release_status=$?
    if [ "${DEBUG_DB_LOCK:-0}" = "1" ] && [ -n "${release_output}" ]; then
      echo "[worker] ${end} db lock release output: ${release_output}"
    fi
    if [ "${release_status}" -ne 0 ]; then
      if [ -n "${release_output}" ]; then
        short_line="$(printf '%s' "${release_output}" | head -n1)"
        echo "[worker] ${end} db lock release error: exit=${release_status} msg=${short_line}"
      else
        echo "[worker] ${end} db lock release error: exit=${release_status}"
      fi
    fi
  fi

  end="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
  echo "[worker] ${end} Cron exit code: ${exit_code}"

  if [ "${RUN_ONCE}" = "1" ]; then
    exit "${exit_code}"
  fi

  if [ "${exit_code}" -ne 0 ]; then
    FAIL_COUNT=$((FAIL_COUNT + 1))
    backoff=$((FAIL_COUNT * 5))
    if [ "${backoff}" -gt 60 ]; then
      backoff=60
    fi
    echo "[worker] ${end} backing off ${backoff}s"
    sleep "${backoff}"
    continue
  fi

  FAIL_COUNT=0
  sleep "${SLEEP_SECONDS}"
done
