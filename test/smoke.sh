#!/bin/sh
# Smoke test: ./smoke.sh BASE_URL ADMIN_USERNAME ADMIN_PASSWORD [create|check]
# create: logs in through the web form and the API, makes a collection and an item
#         with an uploaded image, and prints their ids.
# check:  logs in and lists collections, items and the image URLs (data after a redeploy).
set -eu
B=${1%/}; U=$2; P=$3; MODE=${4:-create}
J=$(mktemp); trap 'rm "$J"' EXIT
# Web login (CSRF form)
page=$(curl -fsS -c "$J" -b "$J" "$B/")
csrf=$(printf '%s' "$page" | sed -n 's/.*name="_csrf_token" value="\([^"]*\)".*/\1/p' | head -1)
code=$(curl -sS -o /dev/null -w '%{http_code} %{redirect_url}' -c "$J" -b "$J" -H "Origin: $B" -H "Referer: $B/" \
  --data-urlencode "_login=$U" --data-urlencode "_password=$P" --data-urlencode "_csrf_token=$csrf" "$B/")
echo "web login: $code"
case "$code" in 302*/|302*/?*login*) echo "web login FAILED"; exit 1;; esac
curl -fsS -b "$J" -o /dev/null -w "dashboard %{http_code}\n" "$B/collections"
# API login (JWT)
tok=$(curl -fsS -H 'Content-Type: application/json' -d "{\"username\":\"$U\",\"password\":\"$P\"}" "$B/api/authentication_token" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
[ -n "$tok" ] || { echo "API login FAILED"; exit 1; }
echo "api login: ok"
H="Authorization: Bearer $tok"
if [ "$MODE" = create ]; then
  col=$(curl -fsS -H "$H" -H 'Content-Type: application/json' -H 'Accept: application/json' -d '{"title":"Smoke test books"}' "$B/api/collections" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
  echo "collection: $col"
  item=$(curl -fsS -H "$H" -H 'Content-Type: application/json' -H 'Accept: application/json' -d "{\"name\":\"Dune\",\"collection\":\"/api/collections/$col\"}" "$B/api/items" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p' | head -1)
  echo "item: $item"
  # a 1200x900 PNG made with PHP's GD if available, else a tiny PNG
  img=$(mktemp --suffix .png)
  if command -v php >/dev/null; then php -r '$i=imagecreatetruecolor(1200,900);for($x=0;$x<1200;$x+=10)imagefilledrectangle($i,$x,0,$x+9,899,imagecolorallocate($i,$x%256,($x*3)%256,128));imagepng($i,$argv[1]);' "$img"
  else printf '\211PNG\r\n\032\n\0\0\0\rIHDR\0\0\0\001\0\0\0\001\010\002\0\0\0\220wS\336\0\0\0\fIDATx\234c\370\017\0\001\001\001\0\030\335\215\260\0\0\0\0IEND\256B`\202' > "$img"; fi
  curl -fsS -H "$H" -H 'Accept: application/json' -F "file=@$img;type=image/png" "$B/api/items/$item/image" | grep -o '"image":"[^"]*"' 
  rm "$img"
fi
curl -fsS -H "$H" -H 'Accept: application/json' "$B/api/collections" | grep -o '"title":"[^"]*"' | head -5
for path in $(curl -fsS -H "$H" -H 'Accept: application/json' "$B/api/items" | grep -o '"image[A-Za-z]*":"[^"]*"' | sed 's/.*:"\(.*\)"/\1/' | sed 's#\\/#/#g'); do
  curl -sS -b "$J" -o /dev/null -w "GET /$path %{http_code} %{size_download} bytes\n" "$B/$path"
done
