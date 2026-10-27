<?php
/*
 * Appbox: run one step of the Kodbox installer (install/index/save, the steps
 * Kodbox's own install/index/auto runs) through index.php's command-line entry
 * point, so a new instance is installed without the installer ever being
 * reachable over HTTP. kod.sh runs it as the appbox user, from
 * /home/appbox/public_html, before nginx and PHP-FPM start.
 *
 *   php kodbox-install-step.php db     database step: SQLite, file cache
 *                                      (the settings earlier images posted)
 *   php kodbox-install-step.php user   administrator step: KODBOX_ADMIN_USER
 *                                      with password KODBOX_ADMIN_PASS
 *
 * The password comes from the environment, so it is never on a command line
 * or in the process list, and nothing here prints it. install/index/auto is not
 * used because it reads the password from argv and cannot take one that
 * starts with "-".
 *
 * Kodbox prints its JSON result ({"code":true,...}) and exits; kod.sh checks it.
 */
if (PHP_SAPI !== 'cli') {
    exit(1);
}

$kodboxRoot = '/home/appbox/public_html';
$step = isset($argv[1]) ? $argv[1] : '';

if ($step === 'db') {
    $params = array(
        'action'          => 'db',
        'dbType'          => 'sqlite',
        'pdoType'         => 'sqlite',
        'dbHost'          => '127.0.0.1',
        'dbUser'          => 'root',
        'dbPwd'           => '',
        'dbName'          => 'kodbox',
        'dbEngine'        => 'innodb',
        'pdoDbHost'       => '127.0.0.1',
        'pdoDbUser'       => 'root',
        'pdoDbPwd'        => '',
        'pdoDbName'       => 'kodbox',
        'pdoDbEngine'     => 'innodb',
        'cacheType'       => 'file',
        'redisHost'       => '127.0.0.1',
        'redisPort'       => '6379',
        'redisAuth'       => '',
        'memcachedHost'   => '127.0.0.1',
        'memcachedPort'   => '11211',
    );
} elseif ($step === 'user') {
    $name = getenv('KODBOX_ADMIN_USER');
    $pass = getenv('KODBOX_ADMIN_PASS');
    if (!is_string($name) || $name === '' || !is_string($pass) || $pass === '') {
        fwrite(STDERR, "kodbox-install-step: KODBOX_ADMIN_USER and KODBOX_ADMIN_PASS must be set\n");
        exit(2);
    }
    $params = array('action' => 'user', 'name' => $name, 'password' => $pass);
} else {
    fwrite(STDERR, "usage: php kodbox-install-step.php db|user\n");
    exit(2);
}

// Keep the password out of the environment Kodbox sees.
putenv('KODBOX_ADMIN_PASS');
unset($_ENV['KODBOX_ADMIN_PASS'], $_SERVER['KODBOX_ADMIN_PASS'], $pass);

// index.php's CLI entry point (init_cli) reads the route and the request
// parameters from argv[1] as a query string and rawurldecodes each value, so
// every character of the password arrives unchanged.
$query = 'install/index/save';
foreach ($params as $key => $value) {
    $query .= '&' . $key . '=' . rawurlencode($value);
}
unset($params);

$argv = array('index.php', $query);
$argc = 2;
$_SERVER['argv'] = $argv;
$_SERVER['argc'] = $argc;
$_SERVER['SCRIPT_NAME'] = 'index.php';
$_SERVER['SCRIPT_FILENAME'] = 'index.php';
$_SERVER['PHP_SELF'] = 'index.php';
unset($query);

if (!chdir($kodboxRoot)) {
    fwrite(STDERR, "kodbox-install-step: cannot enter {$kodboxRoot}\n");
    exit(2);
}
require $kodboxRoot . '/index.php';
