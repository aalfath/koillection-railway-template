[![Deploy on Railway](https://railway.com/button.svg)](https://railway.com/new/template/koillection?utm_medium=integration&utm_source=button&utm_campaign=koillection)

# Koillection on Railway

One-click Railway template for [Koillection](https://github.com/benjaminjonard/koillection), a self-hosted manager for collections of any kind (books, games, cards, stamps, DVDs…) with custom fields, photos, wishlists, loans and a REST API.

**Version:** Koillection 1.8.6, official image `koillection/koillection:1.8.6@sha256:803c6535ba208a077f4d54eabffe6a50e9c15a3db1d6cafad7d72d937b161e0a`, pinned in the [Dockerfile](Dockerfile).

## What the template deploys

| Service | What it does |
|---|---|
| **Koillection** | Web app and API (FrankenPHP), built from this repo. Public Railway domain, health check `/healthz`, restart on failure. |
| **Postgres** | Railway PostgreSQL with a volume: collections, items, users and settings. |
| **Bucket** | Railway object storage: uploaded photos and files, plus the API signing keys. |

Postgres holds the only volume, so the stack fits Railway's **Free plan** (one volume, one bucket, 0.5 GB RAM per service). The app idles at about 130 MB. On Railway at 0.5 GB / 1 vCPU, three 24-megapixel photos uploaded at once peaked at about 430 MB of the limit, including page cache, with no OOM kill.

## After deploy

1. Open the Koillection service's public URL.
2. Sign in as `admin` with the password from the service's **Variables** tab (`ADMIN_PASSWORD`). The account is created on the first boot, before the public port opens, so nobody else can claim the instance. Public sign-up is closed.
3. Add more users under **Admin → Users**.

Changing `ADMIN_PASSWORD` later has no effect: change the password in Koillection's profile settings.

## Variables

| Variable | Default | Notes |
|---|---|---|
| `ADMIN_USERNAME` | `admin` | First admin account, created on the first boot only. 2–32 letters, digits or `_`. |
| `ADMIN_PASSWORD` | generated (24 chars) | First admin password. |
| `APP_SECRET` | generated (48 chars) | Symfony secret for sessions and CSRF. |
| `JWT_PASSPHRASE` | generated (48 chars) | Protects the API signing key. |
| `DB_*` | references to `Postgres` | Database connection. |
| `S3_*` | references to `Bucket` | Upload storage. |
| `PORT` | `8080` | HTTP port. |

Optional (add them yourself): `PHP_TZ` (default `UTC`), `UPLOAD_MAX_FILESIZE` (default `100M`), `ADMIN_EMAIL` (default `admin@example.com`; editable in the app).

## How it works

- `railway/start.sh` replaces upstream's entrypoint. It sizes PHP's memory limit and the FrankenPHP threads from the container's cgroup, waits for Postgres, runs the migrations and the admin bootstrap under a Postgres advisory lock (so overlapping deploys can't migrate twice), restores uploads and the API keys from the Bucket, and starts FrankenPHP on `$PORT`.
- `railway/uploads-sync.sh` watches `/uploads` and copies each new or changed file to the Bucket within a few seconds (and removes deleted ones). It never runs a whole-tree sync, so an older container can't remove files written by a newer one. A full copy also runs every 10 minutes.
- If FrankenPHP or the sync process stops, the container exits non-zero, so Railway's restart policy restarts it.
- Under 1 GB of RAM the start script disables the bundled headless Chromium, which Koillection's scrapers use to render pages; scrapers then fetch pages over plain HTTP. Give the service 1 GB or more to keep Chromium rendering.
- Railway's edge proxies are trusted for `X-Forwarded-*`, so links are `https://` and session cookies are `Secure`.

## Updates

This template builds from this repo's `main` branch. When a new Koillection release is tested here, the pinned image changes in the `Dockerfile` and Railway shows an **update available** notice on your project. Read [CHANGELOG.md](CHANGELOG.md) before applying it. Migrations run on start. Back up Postgres first for major upgrades.

## Local test

`test/compose.yml` runs the stack with rclone's S3 server standing in for the Bucket and the app limited to 512 MB / 1 CPU; `test/smoke.sh` signs in, creates a collection and an item, uploads a photo and reads it back.

Koillection is MIT-licensed by Benjamin Jonard. This wrapper is not affiliated with the Koillection project.
