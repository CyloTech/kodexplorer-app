#!/bin/sh
# The platform mounts a fresh tmpfs on /run in every container it creates, so
# the /run/php directory that the first-boot installer (nginx_php7.sh) makes
# is gone after a restart and php-fpm cannot bind its socket. Recreate it on
# every start, before runit starts php-fpm.
mkdir -p /run/php
