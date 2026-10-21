#!/bin/bash
set -x


# Start Nginx
/usr/sbin/php-fpm8.3 --fpm-config /home/appbox/config/php-fpm/php-fpm.conf &

/usr/sbin/nginx -c /home/appbox/config/nginx/nginx.conf &

if [ -d "/home/appbox/public_html/KODExplorer" ]; then
    rm -rf /home/appbox/public_html/KODExplorer
fi

# Backup user settings if they exist
if [ -f "/home/appbox/public_html/config/setting_user.php" ]; then
    cp -R /home/appbox/public_html/config/setting_user.php /tmp/setting_user.php
fi

if [ ! -f "/home/appbox/public_html/index.php" ]; then
    cp -R /kod_sources/* /home/appbox/public_html/
else
    rm -rf /home/appbox/public_html/.*
    rm -rf /home/appbox/public_html/*
    cp -R /kod_sources/* /home/appbox/public_html/
fi

if [ ! -d "/home/appbox/data/system" ]; then
    mv /home/appbox/public_html/data/system /home/appbox/data/
fi

if [ -f "/tmp/setting_user.php" ]; then
    cp -R /tmp/setting_user.php /home/appbox/public_html/config/setting_user.php
fi

chmod -R 777 /home/appbox/data
chmod -R 777 /home/appbox/public_html

chown -R appbox:appbox /home/appbox/

echo "Waiting for webserver to come up".
until $(curl --output /dev/null --silent --head --fail ${HTTP_DOMAIN}); do
    printf '.'
    sleep 1
done

curl "${HTTP_DOMAIN}/?install/index/save" \
  -H 'accept: application/json, text/javascript, */*; q=0.01' \
  -H 'content-type: application/x-www-form-urlencoded; charset=UTF-8' \
  --data-raw 'action=db&dbType=sqlite&pdoType=sqlite&dbHost=127.0.0.1&dbUser=root&dbPwd=&dbName=kodbox&dbEngine=innodb&pdoDbHost=127.0.0.1&pdoDbUser=root&pdoDbPwd=&pdoDbName=kodbox&pdoDbEngine=innodb&cacheType=file&redisHost=127.0.0.1&redisPort=6379&redisAuth=&memcachedHost=127.0.0.1&memcachedPort=11211&_installTime=1721395348'
curl "${HTTP_DOMAIN}/?install/index/save" \
  -H 'accept: application/json, text/javascript, */*; q=0.01' \
  -H 'content-type: application/x-www-form-urlencoded; charset=UTF-8' \
  --data-raw "action=user&name=admin&password=${ADMIN_PASS}&_installTime=1721394331"


kill $(ps aux | grep '[n]ginx' | awk '{print $2}')
kill $(ps aux | grep '[p]hp' | awk '{print $2}')

# Disable Guest & Demo Logins
rm -fr /home/appbox/data/User/guest
rm -fr /home/appbox/data/User/demo
rm -rf /kod_sources
rm -rf /code_sources