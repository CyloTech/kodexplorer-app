FROM repo.cylo.io/alpine-lep

ENV HTTP_DOMAIN=http://localhost/
ENV ADMIN_PASS=TempPass123

ADD scripts/entrypoint.sh /scripts/entrypoint.sh
RUN chmod -R +x /scripts

RUN rm -fr /etc/nginx/sites-available/default.conf
ADD sources/nginx-site.conf /etc/nginx/sites-available/default.conf

ENTRYPOINT [ "/scripts/entrypoint.sh" ]
CMD [ "/start.sh" ]