<?php
declare(strict_types=1);

$target = getenv('SUITECRM_CONFIG_TARGET') ?: '';
if ($target === '') {
    fwrite(STDERR, "missing config target\n");
    exit(2);
}

$env = static function (string $key, string $fallback = ''): string {
    $value = getenv($key);
    if ($value === false || $value === '') {
        return $fallback;
    }
    return $value;
};

$dbHost = $env('SUITECRM_DB_HOST', $env('DB_HOST'));
$dbPort = $env('SUITECRM_DB_PORT', $env('DB_PORT', '3306'));
$dbName = $env('SUITECRM_DB_NAME', $env('DB_NAME'));
$dbUser = $env('SUITECRM_DB_USER', $env('DB_USER'));
$dbPassword = $env('SUITECRM_DB_PASSWORD', $env('DB_PASSWORD'));
$dbType = $env('SUITECRM_DB_TYPE', $env('DB_TYPE', 'mysqli'));
$dbManager = $env('SUITECRM_DB_MANAGER', $env('DB_MANAGER', 'MysqliManager'));

$siteUrl = $env('SUITECRM_SITE_URL', $env('SITE_URL', $env('PUBLIC_URL', $env('APP_URL', 'http://localhost'))));
$siteName = $env('SUITECRM_SITE_NAME', $env('SITE_NAME', 'SuiteCRM'));
$defaultLanguage = $env('SUITECRM_DEFAULT_LANGUAGE', $env('DEFAULT_LANGUAGE', 'en_us'));
$uniqueKey = $env('SUITECRM_UNIQUE_KEY', $env('UNIQUE_KEY'));

$config = [
    'dbconfig' => [
        'db_host_name' => $dbHost,
        'db_port' => $dbPort,
        'db_name' => $dbName,
        'db_user_name' => $dbUser,
        'db_password' => $dbPassword,
        'db_type' => $dbType,
        'db_manager' => $dbManager,
    ],
    'dbconfigoption' => [],
    'site_url' => rtrim($siteUrl, '/'),
    'site_name' => $siteName,
    'default_language' => $defaultLanguage,
    'installer_locked' => true,
    'cache_dir' => 'cache/',
    'upload_dir' => 'upload/',
    'tmp_dir' => 'cache/tmp/',
    'session_dir' => 'cache/sessions/',
    'log_dir' => 'log/',
    'log_file' => 'suitecrm.log',
];

if ($uniqueKey !== '') {
    $config['unique_key'] = $uniqueKey;
}

$contents = "<?php\n" .
    '// created: ' . gmdate('Y-m-d H:i:s') . "\n" .
    '$sugar_config = ' . var_export($config, true) . ";\n";

if (file_put_contents($target, $contents) === false) {
    fwrite(STDERR, "failed to write config\n");
    exit(5);
}
