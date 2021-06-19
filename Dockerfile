FROM mwaeckerlin/mailforward as build
RUN $PKG_INSTALL postfix postfix-mysql postfix-pcre
RUN addgroup -g 5000 login-user
RUN adduser -H -D -u 5000 -G login-user login-user
RUN mkdir -p /var/mail/domains
RUN chown login-user.login-user /var/mail/domains
RUN postconf -e 'virtual_mailbox_domains = proxy:mysql:/etc/postfix/sql/mysql_virtual_domains_maps.cf'
RUN postconf -e 'virtual_alias_maps = proxy:mysql:/etc/postfix/sql/mysql_virtual_alias_maps.cf, proxy:mysql:/etc/postfix/sql/mysql_virtual_alias_domain_maps.cf, proxy:mysql:/etc/postfix/sql/mysql_virtual_alias_domain_catchall_maps.cf'
RUN postconf -e 'virtual_mailbox_maps = proxy:mysql:/etc/postfix/sql/mysql_virtual_mailbox_maps.cf, proxy:mysql:/etc/postfix/sql/mysql_virtual_alias_domain_mailbox_maps.cf'
RUN postconf -e 'virtual_gid_maps = static:5000'
RUN postconf -e 'virtual_uid_maps = static:5000'
RUN postconf -e 'virtual_minimum_uid = 100'
RUN postconf -e 'virtual_transport = virtual'
RUN postconf -e 'mailbox_transport = virtual'
RUN postconf -e 'local_transport = virtual'
RUN postconf -e 'local_transport_maps = $virtual_mailbox_maps'
RUN postconf -e 'smtputf8_enable = no'
RUN postconf -e 'virtual_transport=lmtp:inet:dovecot'
RUN postconf -e 'mailbox_transport=lmtp:inet:dovecot'
COPY --chown=root:postfix \
    mysql_virtual_alias_domain_catchall_maps.cf \
    mysql_virtual_alias_domain_mailbox_maps.cf \
    mysql_virtual_alias_domain_maps.cf \
    mysql_virtual_alias_maps.cf mysql_virtual_domains_maps.cf \
    mysql_virtual_mailbox_maps.cf \
    /etc/postfix/sql/
COPY start.sh /start.sh
RUN newaliases

FROM mwaeckerlin/scratch
COPY --from=build / /
ENV CONTAINERNAME "postfix"
ENV DB_USER       ""
ENV DB_PASSWORD   ""
ENV DB_HOST       ""
ENV DB_NAME       ""
ENV HOSTNAME      ""
ENV DOMAIN        ""
ENV LOCAL_DOMAINS ""
USER root
CMD /start.sh
VOLUME /var/mail/domains