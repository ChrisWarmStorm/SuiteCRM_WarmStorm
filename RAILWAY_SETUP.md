# SuiteCRM on Railway: DB Persistence + Installer Lockout (Single Volume)

This repo is hardened so redeploys never wipe data and the installer never re-runs against a live database. The entrypoint enforces a persistent external DB, logs clear evidence, and disables the installer when a schema already exists.

## Required Railway Setup (Clicks)

1. Create a Railway project and deploy this repo as a Docker service.
2. Add a persistent database service.
   - Recommended: Railway MySQL (or external MySQL/MariaDB).
   - Do NOT use a local/in-container DB.
3. Add **one** Railway Volume:
   - Required: `/var/www/html/custom` (persists `config.php` + `config_override.php`).

## Required Environment Variables

Set these in the web service (and the worker service if you run one):

- `PUBLIC_URL` = `https://<public-domain>` (no trailing slash, no `:8080`)
- `DB_HOST`
- `DB_PORT` (default `3306`)
- `DB_NAME`
- `DB_USER`
- `DB_PASSWORD`
- `DB_REQUIRE_PERSISTENT` = `1` (default)
- `DB_ALLOW_SCHEMA_INIT` = `0` (default; set to `1` only for first-time install)
- `DB_FINGERPRINT_TABLE` = `users`

Optional:

- `DATABASE_URL` = `mysql://user:pass@host:port/dbname` (used only if DB_* values are unset)

Railway MySQL mappings:

- `DB_HOST` = `${{MYSQLHOST}}`
- `DB_PORT` = `${{MYSQLPORT}}`
- `DB_NAME` = `${{MYSQLDATABASE}}`
- `DB_USER` = `${{MYSQLUSER}}`
- `DB_PASSWORD` = `${{MYSQLPASSWORD}}`

## First Install vs Normal Redeploy

- First install:
  - Set `DB_ALLOW_SCHEMA_INIT=1`.
  - Deploy, complete the SuiteCRM installer.
  - Then set `DB_ALLOW_SCHEMA_INIT=0` and redeploy.
- Normal redeploy:
  - Keep `DB_ALLOW_SCHEMA_INIT=0`.

## Behavior Summary (What the Entrypoint Enforces)

- Fails fast if DB env vars are missing or DB connectivity fails.
- Refuses `DB_HOST=localhost` / `127.0.0.1` / `::1` when `DB_REQUIRE_PERSISTENT=1`.
- Performs read-only schema checks and logs a sanitized DB fingerprint.
- If DB has SuiteCRM tables and `config.php` is missing/empty, it regenerates `config.php` from env vars (no installer run).
- If DB is empty and `DB_ALLOW_SCHEMA_INIT=0`, the container exits with a clear error.
- Installer directory is disabled when a schema exists.

## Evidence Logs (Expected on Boot)

Good boot logs include:

- `[entrypoint] PERSIST_CONFIG_DIR=/var/www/html/custom`
- `[entrypoint] PUBLIC_URL=https://<public-domain>`
- `[entrypoint] site_url_override_set=1`
- `[entrypoint] proxy_https_support=1`
- `[entrypoint] DB_HOST=<host>`
- `[entrypoint] DB_NAME=<name>`
- `[entrypoint] DB_REQUIRE_PERSISTENT=1`
- `[entrypoint] DB_ALLOW_SCHEMA_INIT=0`
- `[entrypoint] DB_TABLES_EXIST=0|1`
- `[entrypoint] DB_CORE_TABLE_COUNT=<n>`
- `[entrypoint] DB_USERS_COUNT=<n>`
- `[entrypoint] DB_SCHEMA_MUTATION=0`
- `[entrypoint] DB_FINGERPRINT=<hash>`
- `[entrypoint] INSTALLER_DISABLED=0|1 reason=<reason>`

If `PUBLIC_URL` is set:

- `[entrypoint] PUBLIC_URL=https://<public-domain>`
- `[entrypoint] site_url_override_set=1`

## Smoke Check

Run inside a container:

```bash
bash docker/smoke-test.sh
```

To assert a pre-initialized DB:

```bash
EXPECT_DB_TABLES_EXIST=1 bash docker/smoke-test.sh
```
