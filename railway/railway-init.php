<?php
// Koillection on Railway: database bootstrap, run from /railway/start.sh.
//   php railway-init.php server-version   prints the PostgreSQL major version (waits for the database)
//   php railway-init.php setup            migrations + first admin, under a Postgres advisory lock
declare(strict_types=1);

function out(string $m): void { fwrite(STDOUT, "[railway-init] $m\n"); }
function fail(string $m): never { fwrite(STDERR, "[railway-init] ERROR: $m\n"); exit(1); }

function connect(): PDO {
    $dsn = sprintf('pgsql:host=%s;port=%s;dbname=%s', getenv('DB_HOST'), getenv('DB_PORT'), getenv('DB_NAME'));
    $deadline = time() + (int) (getenv('DB_WAIT_SECONDS') ?: 240);
    $last = '';
    while (time() < $deadline) {
        try {
            return new PDO($dsn, (string) getenv('DB_USER'), (string) getenv('DB_PASSWORD'), [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_TIMEOUT => 5,
            ]);
        } catch (PDOException $e) {
            $msg = $e->getMessage();
            if ($msg !== $last) { fwrite(STDERR, "[railway-init] waiting for PostgreSQL: " . preg_replace('/password=\S+/', 'password=***', $msg) . "\n"); $last = $msg; }
            sleep(3);
        }
    }
    fail('PostgreSQL did not answer in time');
}

$cmd = $argv[1] ?? '';
if ($cmd === 'server-version') {
    $pdo = connect();
    $num = (int) $pdo->query('SHOW server_version_num')->fetchColumn();
    echo intdiv($num, 10000), "\n";
    exit(0);
}
if ($cmd !== 'setup') { fail('usage: railway-init.php server-version|setup'); }

$pdo = connect();
// Overlapping Railway deploys must not migrate twice: poll a try-lock, never block.
$key = 7284133;
$deadline = time() + 600;
while (!$pdo->query("SELECT pg_try_advisory_lock($key)")->fetchColumn()) {
    if (time() > $deadline) { fail('timed out waiting for the setup lock held by another deploy'); }
    out('another deploy is running setup; waiting');
    sleep(3);
}

$app = '/app/public';
$run = function (string $args) use ($app): void {
    $code = 0;
    passthru('php ' . $app . '/bin/console ' . $args . ' 2>&1', $code);
    if ($code !== 0) { fail("bin/console $args failed (exit $code)"); }
};
out('running database migrations');
$run('doctrine:migrations:migrate --no-interaction --allow-no-migration -q');
$run('app:refresh-cached-values -q');

// First admin, created before the public port opens, so nobody else can claim it.
$users = (int) $pdo->query('SELECT count(*) FROM koi_user')->fetchColumn();
if ($users === 0) {
    out('creating the admin account ' . getenv('ADMIN_USERNAME'));
    $code = 0;
    passthru('php ' . __DIR__ . '/railway-bootstrap-admin.php 2>&1', $code);
    if ($code !== 0) { fail('could not create the admin account'); }
    $admins = (int) $pdo->query("SELECT count(*) FROM koi_user WHERE roles::text LIKE '%ROLE_ADMIN%'")->fetchColumn();
    if ($admins < 1) { fail('admin account missing after bootstrap'); }
} else {
    out("$users user(s) already exist; admin bootstrap skipped");
}
$pdo->query("SELECT pg_advisory_unlock($key)");
out('setup done');
