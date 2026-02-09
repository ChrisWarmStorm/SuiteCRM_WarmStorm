#!/usr/bin/env bash
set -euo pipefail

override_path="/var/www/html/custom/config_override.php"
if [ -n "${SUITECRM_SITE_URL:-}" ]; then
  if [ ! -f "${override_path}" ]; then
    echo "missing config_override.php at ${override_path}"
    exit 1
  fi
  if ! grep -q "\\$sugar_config\\['site_url'\\]" "${override_path}"; then
    echo "missing site_url override in ${override_path}"
    exit 1
  fi
fi

conf_available="/etc/apache2/conf-available/railway-forwarded-https.conf"
conf_enabled="/etc/apache2/conf-enabled/railway-forwarded-https.conf"
if [ ! -f "${conf_available}" ]; then
  echo "missing apache conf: ${conf_available}"
  exit 1
fi
if [ ! -L "${conf_enabled}" ]; then
  echo "apache conf not enabled: ${conf_enabled}"
  exit 1
fi

echo "smoke test ok"
