FROM repo.cylo.net/baseimage

ENV HOME=/home/appbox \
    APEX_CALLBACK=false \
    INST_SCRIPTS=/scripts/install \
    HTTP_DOMAIN=http://localhost/ \
    INSTALL_NGINXPHP=true

RUN apt update && apt install -y php-curl ffmpeg --fix-broken

# Clean up APT when done.
RUN apt-get autoremove -y
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ADD ./scripts/ $INST_SCRIPTS/
ADD ./kodbox/ /kod_sources/
ADD ./sources/ /code_sources/
RUN find $INST_SCRIPTS -name '*.sh' -exec chmod a+x {} +

RUN mv $INST_SCRIPTS/30_installer.sh /etc/my_init.d/30_installer.sh

CMD ["/sbin/my_init"]
