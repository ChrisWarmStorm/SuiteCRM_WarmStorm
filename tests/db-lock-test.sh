#!/usr/bin/env sh
set -eu

fail() {
  echo "FAIL: $*"
  exit 1
}

assert_ok() {
  if ! "$@"; then
    fail "expected success: $*"
  fi
}

assert_fail() {
  if "$@"; then
    fail "expected failure: $*"
  fi
}

write_lock_kv() {
  cat > "$1" <<EOF
DB_TARGET=mysql
DB_HOST=example
DB_NAME=testdb
DB_USER=testuser
DB_FINGERPRINT=$2
FIRST_SEEN_AT=2026-02-12T00:00:00Z
LAST_SEEN_AT=2026-02-12T00:00:00Z
LAST_DB_TABLE_COUNT=$3
EOF
}

lock_check() {
  lock_present=0
  lock_last_db_table_count="0"
  lock_db_fingerprint=""

  if [ -f "${db_lock_file}" ]; then
    lock_present=1
    while IFS='=' read -r key value; do
      case "${key}" in
        DB_FINGERPRINT) lock_db_fingerprint="${value}" ;;
        LAST_DB_TABLE_COUNT) lock_last_db_table_count="${value}" ;;
      esac
    done < "${db_lock_file}"
  fi

  case "${lock_last_db_table_count}" in
    ''|*[!0-9]*) lock_last_db_table_count="0" ;;
  esac

  db_empty=0
  if [ "${db_core_table_count}" = "0" ]; then
    db_empty=1
  fi

  fresh_install_forced=0
  if [ "${SUITECRM_FORCE_FRESH_INSTALL:-0}" = "1" ]; then
    fresh_install_forced=1
  fi

  if [ "${fresh_install_forced}" -eq 1 ] && [ "${db_empty}" -eq 1 ]; then
    rm -f "${db_lock_file}" "${persist_dir}/last_db_fingerprint.txt" "${persist_dir}/install.disabled.marker"
    return 0
  fi

  if [ "${lock_present}" -eq 1 ]; then
    if [ "${SUITECRM_DB_LOCK_RESET:-0}" != "1" ] && [ -n "${lock_db_fingerprint}" ] && [ "${lock_db_fingerprint}" != "${db_fingerprint}" ]; then
      return 1
    fi
    if [ "${db_empty}" -eq 1 ] && [ "${lock_last_db_table_count}" -gt 0 ] && [ "${fresh_install_forced}" -ne 1 ]; then
      return 1
    fi
  fi

  return 0
}

persist_dir="$(mktemp -d)"
db_lock_file="${persist_dir}/.db_lock.json"

db_fingerprint="abc"
db_core_table_count="0"
write_lock_kv "${db_lock_file}" "abc" "123"
assert_fail lock_check

SUITECRM_FORCE_FRESH_INSTALL=1
assert_ok lock_check
[ ! -f "${db_lock_file}" ] || fail "expected lock file to be cleared on fresh install"

SUITECRM_FORCE_FRESH_INSTALL=0
db_core_table_count="5"
db_fingerprint="def"
write_lock_kv "${db_lock_file}" "abc" "5"
assert_fail lock_check

SUITECRM_DB_LOCK_RESET=1
assert_ok lock_check

rm -rf "${persist_dir}"
echo "OK"
