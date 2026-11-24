# Koillection on Railway: official image, pinned by version and digest.
# rclone (also pinned) mirrors the uploads folder to a Railway Bucket so the
# stack needs only one volume (Postgres) and fits Railway's Free plan.
FROM rclone/rclone:1.76.0@sha256:7cbeec24a44f206067597c0368be4de90ae19a64d5113c7d1938bd737a81e466 AS rclone

FROM koillection/koillection:1.8.6@sha256:803c6535ba208a077f4d54eabffe6a50e9c15a3db1d6cafad7d72d937b161e0a

COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone

RUN set -eux; \
    apt-get update -qq; \
    apt-get install -qqy --no-install-recommends inotify-tools; \
    apt-get clean; rm -rf /var/lib/apt/lists/*; \
    rclone version | head -1; inotifywait --help >/dev/null 2>&1 || [ $? -eq 1 ]

COPY railway/ /railway/
RUN set -eux; \
    chmod 755 /railway/start.sh /railway/uploads-sync.sh; \
    chmod 644 /railway/*.php /railway/Caddyfile

EXPOSE 8080
ENTRYPOINT ["/railway/start.sh"]
