# KODExplorer 4.35-6 as deployed (image ID
# sha256:683ec9821a2ffa98373fc52389fde1402714f9f3a369c1e1a684c31cf91027c8,
# registry manifest sha256:d35ec2b7a15f2cc1a5238e818afe1220c907b534cd1ae7bc2f9987b5e5ddacf6,
# built 2020-09-29).
#
# Reconstructed from the image history; the original Dockerfile was not
# committed. The base was the 2020 Cylo baseimage (phusion/baseimage 18.04
# from 2019-06 plus nginx and the bionic php7.2 packages), which no longer
# exists under any tag. scripts/kod.sh and scripts/30_installer.sh are the
# files in that image.
FROM repo.cylo.net/baseimage

ENV HOME=/home/appbox \
    APEX_CALLBACK=true \
    INST_SCRIPTS=/scripts/install \
    HTTP_DOMAIN=http://localhost/ \
    INSTALL_NGINXPHP=true

RUN apt update
RUN apt install -y php-curl --fix-broken
RUN apt autoremove -y
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

ADD scripts/kod.sh scripts/30_installer.sh $INST_SCRIPTS/
RUN find $INST_SCRIPTS -name '*.sh' -exec chmod a+x {} +

RUN mv $INST_SCRIPTS/30_installer.sh /etc/my_init.d/30_installer.sh

CMD ["/sbin/my_init"]
