FROM repo.cylo.io/ubuntu-lep

ENV HTTP_DOMAIN=http://localhost/
ENV ADMIN_PASS=TempPass123

ADD scripts/kod.sh /scripts/kod.sh
RUN chmod -R +x /scripts

ADD sources/nginx-site.conf /

ENTRYPOINT [ "/scripts/kod.sh" ]