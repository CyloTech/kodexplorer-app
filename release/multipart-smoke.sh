#!/bin/sh
# Runs inside the image. PHP's built-in server uses the same multipart
# parser as php-fpm, so a normal upload must still populate $_POST and
# $_FILES after the parser is patched.
set -eu

mkdir -p /tmp/multipart-smoke
cat > /tmp/multipart-smoke/upload.php <<'PHP'
<?php
echo count($_FILES), ':', $_FILES['f']['size'] ?? -1, ':', $_POST['a'] ?? '';
PHP
printf 'hello' > /tmp/multipart-smoke-file.txt

php8.3 -S 127.0.0.1:8089 -t /tmp/multipart-smoke >/dev/null 2>&1 &
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true' EXIT

for attempt in 1 2 3 4 5 6 7 8 9 10; do
    curl -s -o /dev/null http://127.0.0.1:8089/upload.php && break
    sleep 0.5
done

result=$(curl -s -F a=b -F f=@/tmp/multipart-smoke-file.txt http://127.0.0.1:8089/upload.php)
if [ "$result" != "1:5:b" ]; then
    echo "multipart upload returned '$result', expected '1:5:b'" >&2
    exit 1
fi
echo "multipart upload ok"
