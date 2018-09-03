#!/bin/bash
set -x

/bin/sh /scripts/Entrypoint.sh &
sleep 5

if [ ! -f /etc/ke_installed ]; then

    # Start Nginx
#    /usr/sbin/php-fpm7.2 --fpm-config /home/appbox/config/php-fpm/php-fpm.conf &
#    /usr/sbin/nginx -c /home/appbox/config/nginx/nginx.conf &

    echo "Waiting for webserver to come up".
    until $(curl --output /dev/null --silent --head --fail ${HTTP_DOMAIN}); do
        printf '.'
        sleep 1
    done

    rm -fr /home/appbox/config/nginx/sites-enabled/default-site.conf
    mv /nginx-site.conf /home/appbox/config/nginx/sites-enabled/default-site.conf

    if [ ! -d "/home/appbox/public_html/KODExplorer" ]; then
        cd /home/appbox/public_html
        git clone https://github.com/kalcaddle/KODExplorer.git
    else
        cd /home/appbox/public_html/KODExplorer
        git pull
    fi

    chown -R appbox:appbox /home/appbox/public_html/KODExplorer/
    chmod -R 777 /home/appbox/public_html/KODExplorer

    pkill -9 nginx

    echo "Waiting for webserver to come up again".
    until $(curl --output /dev/null --silent --head --fail ${HTTP_DOMAIN}); do
        printf '.'
        sleep 1
    done

    curl "${HTTP_DOMAIN}/index.php"
    curl "${HTTP_DOMAIN}/index.php?user/loginFirst&password=${ADMIN_PASS}"

    ln -s /var/www/apps /home/appbox/public_html/KODExplorer/data/User/admin/home/appbox_apps
    ln -s /var/www/storage /home/appbox/public_html/KODExplorer/data/User/admin/home/appbox_storage

    # Disable Guest & Demo Logins
    rm -fr /home/appbox/public_html/KODExplorer/data/User/guest
    rm -fr /home/appbox/public_html/KODExplorer/data/User/demo

    curl -i -H "Accept: application/json" -H "Content-Type:application/json" -X POST "https://api.cylo.io/v1/apps/installed/$INSTANCE_ID"
    touch /etc/ke_installed
fi

tail -f /etc/resolv.conf
# Start supervisord and services
# exec /usr/bin/supervisord -n -c /home/appbox/config/supervisor/supervisord.conf