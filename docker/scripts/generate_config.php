<?php
declare(strict_types=1);

$root = getenv('SUITECRM_ROOT') ?: '/var/www/html';
$target = getenv('SUITECRM_CONFIG_TARGET') ?: '';

if ($target === '') {
    fwrite(STDERR, "missing config target\n");
    exit(2);
}

if (!is_dir($root)) {
    fwrite(STDERR, "suitecrm root missing\n");
    exit(3);
}

if (!chdir($root)) {
    fwrite(STDERR, "failed to chdir to suitecrm root\n");
    exit(3);
}

if (!file_exists('include/entryPoint.php')) {
    fwrite(STDERR, "include/entryPoint.php missing\n");
    exit(4);
}

define('sugarEntry', true);
require_once 'include/entryPoint.php';
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

$contents = "<?php\n" .
    '// created: ' . gmdate('Y-m-d H:i:s') . "\n" .
    '$sugar_config = ' . var_export($config, true) . ";\n";

if (file_put_contents($target, $contents) === false) {
    fwrite(STDERR, "failed to write config\n");
    exit(5);
}
