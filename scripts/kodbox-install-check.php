<?php
/*
 * Appbox: check that the Kodbox install kod.sh just ran is complete.
 *
 *   php kodbox-install-check.php <admin name>
 *
 * Exits 0 only when config/setting_user.php and data/system/install.lock
 * exist and the SQLite database the settings point at has an enabled
 * administrator 1 with that name, a role and a password. kod.sh runs it after
 * the install steps; any other result makes the install fail.
 */
if (PHP_SAPI !== 'cli') {
    exit(1);
}

define('USER_SYSTEM', '/home/appbox/data/system/');
$settingsFile = '/home/appbox/public_html/config/setting_user.php';
$installLock = USER_SYSTEM . 'install.lock';
$adminName = isset($argv[1]) ? $argv[1] : '';

function install_check_fail($message) {
    fwrite(STDERR, "kodbox-install-check: {$message}\n");
    exit(1);
}

if ($adminName === '') install_check_fail('usage: php kodbox-install-check.php <admin name>');
if (!is_file($settingsFile)) install_check_fail('config/setting_user.php is missing');
if (!is_file($installLock)) install_check_fail('install.lock is missing');

$config = array();
include $settingsFile;
$database = isset($config['database']) && is_array($config['database']) ? $config['database'] : array();
$dbType = isset($database['DB_TYPE']) ? strtolower($database['DB_TYPE']) : '';
if (in_array($dbType, array('sqlite', 'sqlite3'), true) && !empty($database['DB_NAME'])) {
    $dbFile = $database['DB_NAME'];
} elseif ($dbType === 'pdo' && isset($database['DB_DSN']) && stripos($database['DB_DSN'], 'sqlite:') === 0) {
    $dbFile = substr($database['DB_DSN'], strlen('sqlite:'));
} else {
    install_check_fail("unexpected database type '{$dbType}' in config/setting_user.php");
}
if (!is_file($dbFile)) install_check_fail('the SQLite database in config/setting_user.php does not exist');

try {
    $pdo = new PDO('sqlite:' . $dbFile, null, null, array(PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION));
    $query = $pdo->prepare('SELECT "name", "roleID", "status", "password" FROM "user" WHERE "userID" = 1');
    $query->execute();
    $admin = $query->fetch(PDO::FETCH_ASSOC);
} catch (Exception $e) {
    install_check_fail('cannot read the Kodbox database: ' . $e->getMessage());
}
if (!$admin) install_check_fail('administrator 1 does not exist');
if ($admin['name'] !== $adminName) install_check_fail("administrator 1 is not named '{$adminName}'");
if ((int) $admin['status'] !== 1) install_check_fail('administrator 1 is disabled');
if ((int) $admin['roleID'] <= 0) install_check_fail('administrator 1 has no role');
if ((string) $admin['password'] === '') install_check_fail('administrator 1 has no password');

echo "Kodbox administrator '{$adminName}' exists and install.lock is present\n";
exit(0);
