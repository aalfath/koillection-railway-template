<?php
// Creates Koillection's first admin from ADMIN_USERNAME / ADMIN_EMAIL / ADMIN_PASSWORD.
// Same fields as upstream's /first-connection form (SecurityController::firstConnection).
declare(strict_types=1);

use App\Entity\User;
use App\Kernel;
use Symfony\Component\Dotenv\Dotenv;

$root = '/app/public';
require $root . '/vendor/autoload.php';
(new Dotenv())->bootEnv($root . '/.env');

$kernel = new Kernel('prod', false);
$kernel->boot();
$em = $kernel->getContainer()->get('doctrine')->getManager();

if ($em->getRepository(User::class)->count([]) > 0) {
    fwrite(STDOUT, "[railway-init] a user already exists; nothing to do\n");
    exit(0);
}

$user = (new User())
    ->setUsername((string) getenv('ADMIN_USERNAME'))
    ->setEmail((string) getenv('ADMIN_EMAIL'))
    ->setTimezone((string) (getenv('PHP_TZ') ?: 'UTC'))
    ->setEnabled(true)
    ->addRole('ROLE_ADMIN');
$user->setPlainPassword((string) getenv('ADMIN_PASSWORD'));

$em->persist($user);
$em->flush();
fwrite(STDOUT, "[railway-init] admin account created\n");
