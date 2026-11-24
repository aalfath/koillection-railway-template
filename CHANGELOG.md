# Changelog

## 1.8.6-railway.1 (2026-11-24)

First release of the template.

- Koillection 1.8.6, official image pinned by digest (`sha256:803c6535…1e0a`).
- Railway Postgres with the stack's only volume, plus a Railway Bucket for uploads and API keys (fits the Free plan).
- Admin account created on the first boot from generated variables, before the public port opens.
- Migrations under a Postgres advisory lock; non-zero exit when the web server or the upload sync stops.
- PHP memory and FrankenPHP threads sized from the container's limits; headless Chromium scraping disabled below 1 GB RAM.
