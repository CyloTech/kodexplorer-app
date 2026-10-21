#!/bin/bash
set -x

    
# Start Nginx
/usr/sbin/php-fpm7.2 --fpm-config /home/appbox/config/php-fpm/php-fpm.conf &

/usr/sbin/nginx -c /home/appbox/config/nginx/nginx.conf &

if [ -d "/home/appbox/public_html/KODExplorer" ]; then
    rm -rf /home/appbox/public_html/KODExplorer
fi

if [ ! -f "/home/appbox/public_html/index.php" ]; then
    git clone https://github.com/Rid/KODExplorer /home/appbox/public_html
else
    rm -rf /home/appbox/public_html/.*
    rm -rf /home/appbox/public_html/*
    git clone https://github.com/Rid/KODExplorer /home/appbox/public_html
fi

sed -i "s@BASIC_PATH .'data/@'/home/appbox/data/@g" /home/appbox/public_html/config/config.php
sed -i "s@/opt/kodexplorer-data/@/home/appbox/data/@g" /home/appbox/public_html/config/define.php

# Fix stupid permissions
sed -i "s@0640@0755@g" /home/appbox/public_html/config/config.php
sed -i "s@0750@0755@g" /home/appbox/public_html/config/config.php

if [ ! -d "/home/appbox/data/User" ]; then
    mv /home/appbox/public_html/data/* /home/appbox/data/
fi

if [ ! -d "/home/appbox/data/User/admin/data" ]; then
    mkdir -p /home/appbox/data/User/admin/data
fi

mkdir -p /home/appbox/data/User/admin/home/desktop/
echo '{"type":"app_link","content":"ui.path.list(hashDecode('\''L3Zhci93d3cvc3RvcmFnZS8_c'\''));","icon":"folder"}' > /home/appbox/data/User/admin/home/desktop/appbox_storage.oexe
echo '{"type":"app_link","content":"ui.path.list(hashDecode('\''L3Zhci93d3cvYXBwcy8_c'\''));","icon":"folder"}' > /home/appbox/data/User/admin/home/desktop/appbox_apps.oexe

if [ -L "/home/appbox/data/User/admin/home/appbox_storage/storage" ]; then
    rm /home/appbox/data/User/admin/home/appbox_storage/storage
fi

if [ -L "/home/appbox/data/User/admin/home/appbox_storage" ]; then
    rm /home/appbox/data/User/admin/home/appbox_storage
fi

if [ -L "/home/appbox/data/User/admin/home/appbox_apps" ]; then
    rm /home/appbox/data/User/admin/home/appbox_apps
fi

if [ -f "/home/appbox/data/system/install.lock" ]; then
    rm /home/appbox/data/system/install.lock
fi

chmod -R 777 /home/appbox/data
chmod -R 777 /home/appbox/public_html

chown -R appbox:appbox /home/appbox/

echo "Waiting for webserver to come up".
until $(curl --output /dev/null --silent --head --fail ${HTTP_DOMAIN}); do
    printf '.'
    sleep 1
done

curl "${HTTP_DOMAIN}/index.php?user/loginFirst&password=${ADMIN_PASS}"

kill $(ps aux | grep '[n]ginx' | awk '{print $2}')
kill $(ps aux | grep '[p]hp' | awk '{print $2}')

# Disable Guest & Demo Logins
rm -fr /home/appbox/data/User/guest
rm -fr /home/appbox/data/User/demo

