# Deploy and Host Koillection on Railway

Koillection is a self-hosted collection manager for books, games, cards, stamps, DVDs and anything else you collect. You define your own fields, templates, tags and wishlists, add photos and files, track loans and inventories, and share selected collections publicly. It ships a web UI and a REST API.

## About Hosting Koillection

This template runs Koillection 1.8.6 from the official image, pinned by digest, with Railway Postgres and a Railway Bucket. On the first boot it waits for the database, runs the migrations and creates your admin account before the public port opens, so nobody else can claim the instance. After deploy, open the Koillection service's Variables tab, copy `ADMIN_USERNAME` (`admin`) and `ADMIN_PASSWORD`, and sign in. Photos and files are copied to the Bucket and restored on every start, so Postgres needs the only volume and the stack fits Railway's Free plan. Updates arrive as Railway update notices from the template repo.

## Common Use Cases

* Catalogue a book, game, vinyl, card or model collection with your own fields and photos
* Keep wishlists, track loans and run inventories of what you own
* Share chosen collections publicly or read them through the REST API

## Dependencies for Koillection Hosting

* PostgreSQL (Railway Postgres, on a volume): all collections, items, users and settings
* Railway Bucket: uploaded photos, files and the API signing keys

### Deployment Dependencies

* Koillection source and releases: https://github.com/benjaminjonard/koillection (release 1.8.6)
* Official image: https://hub.docker.com/r/koillection/koillection
* Template repo (Dockerfile, start script, changelog): https://github.com/aalfath/koillection-railway-template

### Implementation Details

Services in this template:

* **Koillection**: the web app and API (FrankenPHP) on a public Railway domain, health check `/healthz`. It builds from the template repo, so you get Railway's update notice when a new version is published.
* **Postgres**: Railway's PostgreSQL with its own volume.
* **Bucket**: Railway object storage for uploads, mirrored file by file within seconds of each change.

Sizing: the app idles at about 130 MB and peaked at about 300 MB with three 24-megapixel photos uploaded at once, so it runs on the Free plan (0.5 GB per service). Below 1 GB of RAM the start script turns off Koillection's headless-Chromium scraper rendering, and scrapers fetch pages over plain HTTP instead. Give the service 1 GB or more to use Chromium rendering.

To add more users, sign in as the admin and use Admin, then Users. Public sign-up stays closed. Optional: set `PHP_TZ` (for example `Europe/Paris`) and `UPLOAD_MAX_FILESIZE` (default `100M`) on the Koillection service. The REST API takes a token from `POST https://YOUR-DOMAIN/api/authentication_token` with `{"username": "admin", "password": "..."}`; API docs are at `https://YOUR-DOMAIN/api`.

## Why Deploy Koillection on Railway?

<!-- Recommended: Keep this section as shown below -->
Railway is a singular platform to deploy your infrastructure stack. Railway will host your infrastructure so you don't have to deal with configuration, while allowing you to vertically and horizontally scale it.

By deploying Koillection on Railway, you are one step closer to supporting a complete full-stack application with minimal burden. Host your servers, databases, AI agents, and more on Railway.
<!-- End recommended section -->
