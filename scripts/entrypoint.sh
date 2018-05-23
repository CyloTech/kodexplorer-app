#!/bin/bash
set -x

if [ ! -f /etc/ke_installed ]; then

    cd /var/www/html
    git clone https://github.com/kalcaddle/KODExplorer.git
    chown -R nginx:nginx /var/www/html/KODExplorer/
    chmod -R 777 /var/www/html/KODExplorer

    # Start Nginx
    /usr/local/sbin/php-fpm --nodaemonize --fpm-config /usr/local/etc/php-fpm.d/www.conf &
    /usr/sbin/nginx &

    echo "Waiting for webserver to come up".
    until $(curl --output /dev/null --silent --head --fail ${HTTP_DOMAIN}); do
        printf '.'
        sleep 1
    done

    curl "${HTTP_DOMAIN}/index.php"
    curl "${HTTP_DOMAIN}/index.php?user/loginFirst&password=${ADMIN_PASS}"
    ln -s /var/www/apps /var/www/html/KODExplorer/data/User/admin/home/appbox_apps
    ln -s /var/www/storage /var/www/html/KODExplorer/data/User/admin/home/appbox_storage

    # Disable Guest & Demo Logins
    rm -fr /var/www/html/KODExplorer/data/User/guest
    rm -fr /var/www/html/KODExplorer/data/User/demo

    curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST "https://api.cylo.io/v1/apps/installed/$INSTANCE_ID"
    touch /etc/ke_installed

    pkill -9 nginx
    pkill -9 php
fi

exec "$@"