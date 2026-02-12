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

Set these in the web service (and the worker service if you run one). You can either:
- Set `DB_*` explicitly, or
- Rely on Railway's injected `MYSQL*` variables (auto-mapped by the entrypoint).

- `PUBLIC_URL` = `https://<public-domain>` (no trailing slash, no `:8080`)
- `DB_HOST`
- `DB_PORT` (default `3306`)
- `DB_NAME`
- `DB_USER`
- `DB_PASSWORD`
- `DB_REQUIRE_PERSISTENT` = `1` (default)
- `DB_ALLOW_SCHEMA_INIT` = `0` (default; set to `1` only for first-time install)
- `DB_FINGERPRINT_TABLE` = `users`
- `SUITECRM_DB_LOCK` = `1` (default)
- `SUITECRM_DB_LOCK_RESET` = `0` (default; set to `1` to accept a different DB)
- `SUITECRM_FORCE_FRESH_INSTALL` = `0` (default; set to `1` only when DB is empty and you want a clean install)

Optional:

- `DATABASE_URL` = `mysql://user:pass@host:port/dbname` (used only if DB_* values are unset)

Railway MySQL mappings (auto-detected; no need to manually set DB_* if you use these):

- `DB_HOST` = `${{MYSQLHOST}}`
- `DB_PORT` = `${{MYSQLPORT}}`
- `DB_NAME` = `${{MYSQLDATABASE}}`
- `DB_USER` = `${{MYSQLUSER}}`
- `DB_PASSWORD` = `${{MYSQLPASSWORD}}`

Priority order:
- Explicit `DB_*`
- `DATABASE_URL` (mysql/mariadb)
- Railway `MYSQL*` fallback

Example (Railway MySQL injection only):

```bash
PUBLIC_URL=https://your-app.up.railway.app
DB_REQUIRE_PERSISTENT=1
DB_ALLOW_SCHEMA_INIT=1   # first install only; switch to 0 after installer completes
DB_FINGERPRINT_TABLE=users
SUITECRM_DB_LOCK=1
SUITECRM_DB_LOCK_RESET=0
SUITECRM_FORCE_FRESH_INSTALL=0
# Do not set DB_*; Railway provides MYSQLHOST/MYSQLUSER/MYSQLPASSWORD/MYSQLDATABASE/MYSQLPORT
```

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
- Enforces a DB lock (`.db_lock.json`) and refuses to run if the DB fingerprint changes (unless `SUITECRM_DB_LOCK_RESET=1`).
- If DB is empty but the lock indicates prior tables, it exits unless `SUITECRM_FORCE_FRESH_INSTALL=1`.
- If DB has SuiteCRM tables and `config.php` is missing/empty, it regenerates `config.php` from env vars (no installer run).
- Detects Postgres connections and fails fast with a clear message.
- Installer directory is disabled when a schema exists.

## Evidence Logs (Expected on Boot)

Good boot logs include:

- `[entrypoint] PERSIST_CONFIG_DIR=/var/www/html/custom`
- `[entrypoint] PUBLIC_URL=https://<public-domain>`
- `[entrypoint] site_url_override_set=1`
- `[entrypoint] proxy_https_support=1`
- `[entrypoint] DB_HOST=<host>`
- `[entrypoint] DB_NAME=<name>`
- `[entrypoint] DB_TARGET=mysql host=<masked> port=<port> db=<name> user=<masked> source=<DB_VARS|DATABASE_URL|RAILWAY_MYSQL_VARS>`
- `[entrypoint] DB_SERVER=version:<version> host:<masked>`
- `[entrypoint] DB_REQUIRE_PERSISTENT=1`
- `[entrypoint] DB_ALLOW_SCHEMA_INIT=0`
- `[entrypoint] SUITECRM_DB_LOCK=1`
- `[entrypoint] SUITECRM_DB_LOCK_RESET=0`
- `[entrypoint] SUITECRM_FORCE_FRESH_INSTALL=0`
- `[entrypoint] DB_TABLES_EXIST=0|1`
- `[entrypoint] DB_CORE_TABLE_COUNT=<n>`
- `[entrypoint] DB_USERS_COUNT=<n>`
- `[entrypoint] DB_SCHEMA_MUTATION=0`
- `[entrypoint] DB_FINGERPRINT=<hash>`
- `[entrypoint] DB_EMPTY=yes|no`
- `[entrypoint] DB_LOCK_PRESENT=yes|no`
- `[entrypoint] DB_LOCK_FINGERPRINT_MATCHES=yes|no`
- `[entrypoint] FRESH_INSTALL_FORCED=yes|no`
- `[entrypoint] INSTALLER_DISABLED=0|1 reason=<reason>`

If `PUBLIC_URL` is set:

- `[entrypoint] PUBLIC_URL=https://<public-domain>`
- `[entrypoint] site_url_override_set=1`

## Smoke Check

Run inside a container (this invokes the entrypoint with `SMOKE_CHECK=1`):

```bash
bash docker/smoke-test.sh
```

To assert a pre-initialized DB:

```bash
EXPECT_DB_TABLES_EXIST=1 bash docker/smoke-test.sh
```

If the entrypoint is not at `./docker-entrypoint.sh`, set:

```bash
ENTRYPOINT_PATH=/path/to/docker-entrypoint.sh bash docker/smoke-test.sh
```
