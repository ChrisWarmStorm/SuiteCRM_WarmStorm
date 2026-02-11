#!/usr/bin/env bash
set -euo pipefail

entrypoint_path="${ENTRYPOINT_PATH:-./docker-entrypoint.sh}"

if [ ! -x "${entrypoint_path}" ]; then
  echo "entrypoint not executable at ${entrypoint_path}"
  exit 1
fi

log_file="$(mktemp)"
if ! SMOKE_CHECK=1 "${entrypoint_path}" /bin/true >"${log_file}" 2>&1; then
  cat "${log_file}"
  rm -f "${log_file}"
  exit 1
fi

if ! grep -q "^\[entrypoint\] DB_TARGET=mysql" "${log_file}"; then
  echo "missing DB_TARGET log line"
  cat "${log_file}"
  rm -f "${log_file}"
  exit 1
fi

if [ "${EXPECT_DB_TABLES_EXIST:-}" = "1" ]; then
  if ! grep -q "^\[entrypoint\] DB_TABLES_EXIST=1" "${log_file}"; then
    echo "EXPECT_DB_TABLES_EXIST=1 but DB_TABLES_EXIST was not 1"
    cat "${log_file}"
    rm -f "${log_file}"
    exit 1
  fi
fi

if [ "${EXPECT_DB_TABLES_EXIST:-}" = "0" ]; then
  if ! grep -q "^\[entrypoint\] DB_TABLES_EXIST=0" "${log_file}"; then
    echo "EXPECT_DB_TABLES_EXIST=0 but DB_TABLES_EXIST was not 0"
    cat "${log_file}"
    rm -f "${log_file}"
    exit 1
  fi
fi

rm -f "${log_file}"
echo "smoke test ok"
