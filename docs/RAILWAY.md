# SuiteCRM on Railway (Docker, PHP 8.2)

This repo is wired for Railway Docker deployments with a separate scheduler worker. The container detects the correct web root at runtime and binds Apache to Railway's `$PORT`.

## Project Setup

1. Create a Railway project in region `europe-west4`.
2. Add a MariaDB or MySQL plugin.
3. Create two services from this repo using Docker (default).
4. Web service with a public domain enabled.
5. Worker service with no public domain.
6. Scale the worker service to **1** instance.

## Required Environment Variables

Set these in **both** services:

- `DB_HOST`
- `DB_PORT`
- `DB_NAME`
- `DB_USER`
- `DB_PASSWORD`
- `APP_URL` (public base URL of the web service, used to set `site_url`)

Database must be MySQL or MariaDB. Postgres is not supported for SuiteCRM.

Railway MySQL/MariaDB mapping (plugin var names vary by plugin/version):

- `DB_HOST` = `${{MYSQLHOST}}`
- `DB_PORT` = `${{MYSQLPORT}}`
- `DB_NAME` = `${{MYSQLDATABASE}}`
- `DB_USER` = `${{MYSQLUSER}}`
- `DB_PASSWORD` = `${{MYSQLPASSWORD}}`

## Optional Environment Variables

- `ENABLE_CRON_DB_LOCK=1` to use a MySQL advisory lock around each cron run.
- `RUN_ONCE=1` to run a single cron cycle and exit (debug).
- `SLEEP_SECONDS=60` to change the worker loop interval.
- `APP_DIR=/var/www/html` if your app path differs (rare).
- `PERSIST_CONFIG_DIR=/var/www/html/custom` to override where `config.php` and `config_override.php` are persisted.

## Web Service Deployment

1. Create the web service from this repo (Docker).
2. Set environment variables (see above).
3. Deploy. The container will log the listen port and chosen DocumentRoot.

DocumentRoot selection:

- If `/var/www/html/public` exists, DocumentRoot is `/var/www/html/public`.
- Otherwise, DocumentRoot is `/var/www/html`.

## Worker Service Deployment

1. Create the worker service from this repo (Docker).
2. Set environment variables (same as web service).
3. Set **Start Command** to `./railway-worker.sh`.
4. Deploy. The worker logs each cron cycle and exit code.

Worker volume mount:

- Mount the same single volume at `/var/www/html/custom` so the worker reads the persisted config.

Cron path selection order:

- `/var/www/html/public/legacy/cron.php`
- `/var/www/html/legacy/cron.php`
- `/var/www/html/cron.php`

## Volumes (Required)

Railway filesystem is ephemeral. In single-volume mode, you must persist only `PERSIST_CONFIG_DIR` and accept that uploads/cache/data are ephemeral.

This repo layout (no `public/`):

Required mount (the ONLY required mount):

- `/var/www/html/custom` (PERSIST_CONFIG_DIR; stores `config.php` and `config_override.php`)

Notes:

- Do NOT mount the whole `/var/www/html` root.
- `/var/www/html/upload` is ephemeral in this mode; attachments will not persist across redeploy.
- `/var/www/html/cache` and `/var/www/html/data` are ephemeral and safe to regenerate.

Note on config persistence:

- The entrypoint seeds `config_override.php` from `config_override.php.dist` and symlinks `config.php` and `config_override.php` into `PERSIST_CONFIG_DIR` (default is `custom`).
- To persist config, mount a volume for the `custom` directory (or set `PERSIST_CONFIG_DIR` to a different mounted path).

## First-Time Install

1. Open the web service public domain.
2. Follow the SuiteCRM installer.
3. Choose **MySQL** as the database type.
4. Use the same `DB_*` values configured in Railway.
5. Set the **Site URL** to `APP_URL`.

## Reverse Proxy and HTTPS

- Apache sets `HTTPS=on` when `X-Forwarded-Proto: https` is present.
- Ensure `APP_URL` is the public HTTPS URL to avoid redirect loops.

## Acceptance Checklist

Web service logs must include:

- `[entrypoint] Apache listening on: <port>`
- `[entrypoint] DocumentRoot: <path>`
- `[entrypoint] APP_ROOT: <path>`
- `[entrypoint] PERSIST_CONFIG_DIR: <path>`
- `[entrypoint] Persisting config to: <path>`
- `[entrypoint] config.php -> <target> (symlink)`
- `[entrypoint] config_override.php -> <target> (symlink)`
- `CONFIG_WRITABLE=1`
- `OVERRIDE_WRITABLE=1`
- `[entrypoint] Effective Listen directives: ...` (only one `Listen` line and it matches `<port>`)
- `[entrypoint] Rewrite module enabled: true`

Worker service logs must include:

- `starting scheduler`
- `Cron path selected: <path>`
- `Cron exit code: <code>`
- If `ENABLE_CRON_DB_LOCK=1` and lock is busy: `db lock not acquired, skipping cycle`
- If DB lock errors: `db lock error: exit=<code> msg=<line>`

UI behavior:

- Web UI shows installer or SuiteCRM login page.
- After install + redeploy with volume mounted, installer does not re-run.
- Worker runs every 60 seconds (or your `SLEEP_SECONDS`).

## Troubleshooting

Redirect loops:

- Ensure `APP_URL` matches the public domain scheme (https).
- Check that the proxy header is set in logs and `site_url` is correct.

404s or missing assets:

- Confirm `DocumentRoot` log matches your layout.
- Ensure Apache rewrite module is enabled in logs.

Installer not persisting after redeploy:

- Confirm volumes are mounted on the correct paths for your layout.
- Verify `custom` is volume-backed so `config.php` persists.

Cron not running:

- Confirm worker scale is **1**.
- Check worker logs for `Cron path selected` and `Cron exit code`.
- Ensure `cron.php` exists in the detected location.

Missing PHP extensions:

- The Docker image installs `mysqli`, `curl`, `mbstring`, `xml`, `zip`, `gd`, `intl`, `soap`.
- Optional: `imap` (inbound email) and `ldap` (directory auth) can be added if needed.

## Local Docker Test

```bash
docker build -t suitecrm-railway .
docker run --rm -e PORT=3000 -p 3000:3000 suitecrm-railway
```
