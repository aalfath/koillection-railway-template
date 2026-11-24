#!/bin/bash
# Koillection start script for Railway (replaces upstream docker/entrypoint.sh).
# - fails (exit 1) on any setup error, so Railway's ON_FAILURE policy restarts it
# - runs migrations under a Postgres advisory lock and creates the admin
#   from ADMIN_USERNAME / ADMIN_PASSWORD before the public port opens
# - keeps /uploads and the API (JWT) keys in a Railway Bucket (UPLOADS_STORAGE=s3),
#   so Postgres holds the only volume and the stack fits Railway's Free plan
# - sizes PHP and FrankenPHP from the container's cgroup limits
set -Eeuo pipefail

log() { echo "[railway] $*"; }
die() { echo "[railway] ERROR: $*" >&2; exit 1; }

APP=/app/public
RUN_AS=(setpriv --reuid=koillection --regid=koillection --init-groups)
export HOME=/tmp

# ---------- required settings ----------
: "${PORT:=8080}"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "PORT must be a number"
for v in APP_SECRET JWT_PASSPHRASE ADMIN_PASSWORD DB_HOST DB_PORT DB_NAME DB_USER DB_PASSWORD; do
  [ -n "${!v:-}" ] || die "$v is empty. It is set by the Railway template; check the service variables."
done
[ "${#APP_SECRET}" -ge 16 ] || die "APP_SECRET must be at least 16 characters"
[ "${#ADMIN_PASSWORD}" -ge 12 ] || die "ADMIN_PASSWORD must be at least 12 characters"
export ADMIN_USERNAME="${ADMIN_USERNAME:-admin}"
[[ "$ADMIN_USERNAME" =~ ^[A-Za-z0-9_]{2,32}$ ]] || die "ADMIN_USERNAME may use 2-32 letters, digits or _"
export ADMIN_EMAIL="${ADMIN_EMAIL:-admin@example.com}"
UPLOADS_STORAGE="${UPLOADS_STORAGE:-s3}"

# ---------- resources from the cgroup ----------
mem_bytes=$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo max)
[[ "$mem_bytes" =~ ^[0-9]+$ ]] || mem_bytes=$(awk '/MemTotal/{print $2*1024}' /proc/meminfo)
mem_mb=$(( mem_bytes / 1024 / 1024 ))
cpus=1
if read -r quota period < /sys/fs/cgroup/cpu.max 2>/dev/null && [[ "$quota" =~ ^[0-9]+$ ]]; then
  cpus=$(( (quota + period - 1) / period ))
else
  cpus=$(nproc)
fi
[ "$cpus" -ge 1 ] || cpus=1; [ "$cpus" -le 4 ] || cpus=4
export GOMAXPROCS="${GOMAXPROCS:-$cpus}"
php_mem=$(( mem_mb * 45 / 100 )); [ "$php_mem" -le 512 ] || php_mem=512; [ "$php_mem" -ge 128 ] || php_mem=128
PHP_MEMORY_LIMIT="${PHP_MEMORY_LIMIT:-${php_mem}M}"
threads=$(( cpus * 2 )); [ "$threads" -le 8 ] || threads=8
export FRANKENPHP_THREADS_NUMBER="${FRANKENPHP_THREADS_NUMBER:-$threads}"
export FRANKENPHP_WORKERS_NUMBER="${FRANKENPHP_WORKERS_NUMBER:-1}"
[ "$FRANKENPHP_WORKERS_NUMBER" -lt "$FRANKENPHP_THREADS_NUMBER" ] || FRANKENPHP_THREADS_NUMBER=$(( FRANKENPHP_WORKERS_NUMBER + 1 ))
export UPLOAD_MAX_FILESIZE="${UPLOAD_MAX_FILESIZE:-100M}"
# The upstream image bakes FRANKENPHP_SERVER_NAME=:80; listen on Railway's PORT instead.
export FRANKENPHP_SERVER_NAME=":${PORT}"
log "memory ${mem_mb} MB, cpus ${cpus}: PHP memory_limit ${PHP_MEMORY_LIMIT}, ${FRANKENPHP_THREADS_NUMBER} PHP threads"

# Scrapers render pages in headless Chromium when it is installed. Chromium needs
# far more RAM than Railway's 0.5 GB Free plan, so below 1 GB it is switched off
# and scrapers fetch pages with the plain HTTP client instead.
if [ "$mem_mb" -lt "${CHROMIUM_MIN_MEMORY_MB:-1000}" ]; then
  for b in /usr/bin/chromium /usr/bin/chromium-browser; do
    [ -e "$b" ] && mv "$b" "$b.disabled-low-memory"
  done
  log "Chromium scraping off (under ${CHROMIUM_MIN_MEMORY_MB:-1000} MB RAM); scrapers use plain HTTP"
else
  for b in /usr/bin/chromium /usr/bin/chromium-browser; do
    [ -e "$b.disabled-low-memory" ] && mv "$b.disabled-low-memory" "$b"
  done
fi

# ---------- PHP settings ----------
cat > /usr/local/etc/php/conf.d/zz-railway.ini <<INI
memory_limit=${PHP_MEMORY_LIMIT}
upload_max_filesize=${UPLOAD_MAX_FILESIZE}
post_max_size=${UPLOAD_MAX_FILESIZE}
date.timezone=${PHP_TZ:-UTC}
session.cookie_secure=${HTTPS_ENABLED:-1}
opcache.memory_consumption=${OPCACHE_MEMORY_MB:-96}
apc.shm_size=32M
INI

# ---------- Symfony environment (.env.local, read by the app) ----------
DB_VERSION="${DB_VERSION:-$(php /railway/railway-init.php server-version)}" || die "could not reach PostgreSQL"
env_line() { printf '%s=%s\n' "$1" "$(printf '%s' "$2" | sed "s/'/'\\\\''/g; s/^/'/; s/\$/'/")"; }
{
  env_line APP_ENV prod
  env_line APP_DEBUG 0
  env_line APP_SECRET "$APP_SECRET"
  env_line JWT_SECRET_KEY '%kernel.project_dir%/config/jwt/private.pem'
  env_line JWT_PUBLIC_KEY '%kernel.project_dir%/config/jwt/public.pem'
  env_line JWT_PASSPHRASE "$JWT_PASSPHRASE"
  env_line DB_DRIVER pdo_pgsql
  env_line DB_NAME "$DB_NAME"
  env_line DB_HOST "$DB_HOST"
  env_line DB_PORT "$DB_PORT"
  env_line DB_USER "$DB_USER"
  env_line DB_PASSWORD "$DB_PASSWORD"
  env_line DB_VERSION "$DB_VERSION"
  env_line CORS_ALLOW_ORIGIN "${CORS_ALLOW_ORIGIN:-^https?://(localhost|127\\.0\\.0\\.1)(:[0-9]+)?\$}"
} > "$APP/.env.local"
chown koillection:koillection "$APP/.env.local"; chmod 600 "$APP/.env.local"
# Railway's edge proxies (and the local FrankenPHP) may set X-Forwarded-*.
export SYMFONY_TRUSTED_PROXIES="${SYMFONY_TRUSTED_PROXIES:-127.0.0.1,100.64.0.0/10,152.233.0.0/16,fd00::/8}"
export SYMFONY_TRUSTED_HEADERS="${SYMFONY_TRUSTED_HEADERS:-x-forwarded-for,x-forwarded-proto,x-forwarded-port,x-forwarded-host}"

# ---------- uploads and API keys ----------
mkdir -p /uploads /data /config "$APP/config/jwt" "$APP/var/log"
if [ ! -L "$APP/public/uploads" ]; then
  rm -r "$APP/public/uploads"
  ln -s /uploads "$APP/public/uploads"
fi
if [ "$UPLOADS_STORAGE" = "s3" ]; then
  for v in S3_ENDPOINT S3_BUCKET S3_ACCESS_KEY_ID S3_SECRET_ACCESS_KEY; do
    [ -n "${!v:-}" ] || die "$v is empty. The template stores uploads in a Railway Bucket; set UPLOADS_STORAGE=local only if /uploads is on a volume."
  done
  case "$S3_ENDPOINT" in http://*|https://*) ;; *) S3_ENDPOINT="https://$S3_ENDPOINT";; esac
  export RCLONE_CONFIG_BUCKET_TYPE=s3 RCLONE_CONFIG_BUCKET_PROVIDER=Other \
    RCLONE_CONFIG_BUCKET_ENDPOINT="$S3_ENDPOINT" RCLONE_CONFIG_BUCKET_REGION="${S3_REGION:-auto}" \
    RCLONE_CONFIG_BUCKET_ACCESS_KEY_ID="$S3_ACCESS_KEY_ID" RCLONE_CONFIG_BUCKET_SECRET_ACCESS_KEY="$S3_SECRET_ACCESS_KEY" \
    RCLONE_CONFIG_BUCKET_FORCE_PATH_STYLE="${S3_FORCE_PATH_STYLE:-false}" RCLONE_CONFIG_BUCKET_NO_CHECK_BUCKET=true
  export RCLONE_REMOTE="bucket:${S3_BUCKET}"
  unset S3_SECRET_ACCESS_KEY
  log "restoring uploads from the bucket"
  # rclone exits 3 when the prefix doesn't exist yet (a new, empty bucket).
  rc=0; rclone copy "$RCLONE_REMOTE/uploads" /uploads --transfers 4 --checkers 8 -q || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || die "could not read uploads from the Railway Bucket (rclone exit $rc)"
  rc=0; rclone copy "$RCLONE_REMOTE/jwt" "$APP/config/jwt" -q || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || die "could not read API keys from the Railway Bucket (rclone exit $rc)"
  log "restored $(find /uploads -type f | wc -l) upload files"
elif [ "$UPLOADS_STORAGE" = "local" ]; then
  log "UPLOADS_STORAGE=local: uploads stay in /uploads (mount a volume there or they are lost on redeploy)"
  mkdir -p /uploads/.railway-jwt
  cp -n /uploads/.railway-jwt/*.pem "$APP/config/jwt/" 2>/dev/null || true
else
  die "UPLOADS_STORAGE must be s3 or local"
fi
chown -R koillection:koillection /uploads "$APP/config/jwt" "$APP/var" /data /config

# ---------- database: wait, migrate, create the admin (under a lock) ----------
"${RUN_AS[@]}" php /railway/railway-init.php setup || die "database setup failed"

# API (JWT) key pair, kept across redeploys
if [ ! -s "$APP/config/jwt/private.pem" ]; then
  "${RUN_AS[@]}" php "$APP/bin/console" lexik:jwt:generate-keypair --skip-if-exists -q || die "could not create API keys"
fi
if [ "$UPLOADS_STORAGE" = "s3" ]; then
  rclone copy "$APP/config/jwt" "$RCLONE_REMOTE/jwt" -q || die "could not save API keys to the Railway Bucket"
else
  cp "$APP/config/jwt/"*.pem /uploads/.railway-jwt/
fi
"${RUN_AS[@]}" php "$APP/bin/console" cache:warmup -q || die "cache warmup failed"

# ---------- run ----------
unset APP_SECRET JWT_PASSPHRASE DB_PASSWORD ADMIN_PASSWORD
cd "$APP"
pids=()
"${RUN_AS[@]}" frankenphp run --config /railway/Caddyfile --adapter caddyfile &
web=$!; pids+=("$web")
sync=""
if [ "$UPLOADS_STORAGE" = "s3" ]; then
  /railway/uploads-sync.sh &
  sync=$!; pids+=("$sync")
fi

stopping=0
on_term() {
  stopping=1
  log "stopping"
  kill -TERM "$web" 2>/dev/null || true
  [ -n "$sync" ] && kill -TERM "$sync" 2>/dev/null || true
  wait "$web" 2>/dev/null || true
  [ -n "$sync" ] && wait "$sync" 2>/dev/null || true
  exit 0
}
trap on_term TERM INT
trap - ERR
set +e

# Exit non-zero as soon as either process stops, so Railway restarts the service.
while :; do
  for p in "${pids[@]}"; do
    if ! kill -0 "$p" 2>/dev/null; then
      wait "$p"; code=$?
      [ "$stopping" = 1 ] && exit 0
      if [ "$p" = "$web" ]; then
        log "FrankenPHP stopped (exit $code)"
        [ -n "$sync" ] && kill -TERM "$sync" 2>/dev/null && wait "$sync" 2>/dev/null
      else
        log "uploads sync stopped (exit $code)"
        kill -TERM "$web" 2>/dev/null; wait "$web" 2>/dev/null
      fi
      [ "$code" -ne 0 ] || code=1
      exit "$code"
    fi
  done
  sleep 2
done
