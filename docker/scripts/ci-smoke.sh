#!/usr/bin/env sh
set -eu

if [ ! -f "include/entryPoint.php" ]; then
  echo "Missing include/entryPoint.php"
  exit 1
fi

if command -v shellcheck >/dev/null 2>&1; then
  shellcheck -n docker-entrypoint.sh
elif command -v bash >/dev/null 2>&1; then
  bash -n docker-entrypoint.sh
else
  sh -n docker-entrypoint.sh
fi

php -l docker/scripts/generate_config.php >/dev/null
