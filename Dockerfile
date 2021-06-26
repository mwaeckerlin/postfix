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
RUN postconf -e 'smtputf8_enable = no'
RUN postconf -e 'virtual_transport=lmtp:inet:dovecot'
RUN postconf -e 'mailbox_transport=lmtp:inet:dovecot'

# debugging
RUN postconf -e 'debug_peer_list=192.168.80.1'
RUN postconf -e 'smtpd_tls_loglevel = 2'
RUN postconf -e 'lmtp_tls_loglevel = 2'
RUN postconf -e 'smtp_tls_loglevel = 2'

# SASL
RUN postconf -e 'broken_sasl_auth_clients = yes'
#RUN postconf -e 'smtp_sasl_auth_enable = yes'
#RUN postconf -e 'smtp_sasl_path = inet:dovecot:12345'
#RUN postconf -e 'smtp_sasl_type = dovecot'
#RUN postconf -e 'smtp_use_tls = no'
#RUN postconf -e 'smtp_sasl_security_options = noanonymous'
RUN postconf -e 'smtpd_sasl_auth_enable = yes'
RUN postconf -e 'smtpd_sasl_path = inet:dovecot:12345'
RUN postconf -e 'smtpd_sasl_type = dovecot'
RUN postconf -e 'smtpd_use_tls = no'
RUN postconf -e 'smtpd_sasl_security_options = noanonymous'

# antispam
RUN postconf -e 'smtpd_hard_error_limit = 1'
RUN postconf -e 'smtpd_helo_required = yes'
RUN postconf -e 'smtpd_helo_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_invalid_hostname, reject_non_fqdn_hostname, reject_unauth_pipelining'
RUN postconf -e 'smtpd_sender_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_non_fqdn_sender, reject_unauth_pipelining'
RUN postconf -e 'smtpd_recipient_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unknown_recipient_domain, reject_non_fqdn_recipient, reject_unauth_pipelining, reject_rbl_client ix.dnsbl.manitu.net, reject_rbl_client sbl.spamhaus.org, reject_rbl_client xbl.spamhaus.org, check_policy_service inet:127.0.0.1:10023'
RUN postconf -e 'smtpd_client_restrictions = permit_sasl_authenticated, reject_invalid_hostname, reject_rhsbl_sender dbl.spamhaus.org, reject_rhsbl_client dbl.spamhaus.org, reject_rhsbl_helo dbl.spamhaus.org'
RUN postconf -e 'smtpd_relay_restrictions = permit_sasl_authenticated, reject_unknown_recipient_domain, reject_non_fqdn_recipient, reject_unauth_pipelining, reject_unauth_destination, reject_rbl_client ix.dnsbl.manitu.net, reject_rbl_client sbl.spamhaus.org, reject_rbl_client xbl.spamhaus.org'

COPY --chown=root:postfix \
    mysql_virtual_alias_domain_catchall_maps.cf \
    mysql_virtual_alias_domain_mailbox_maps.cf \
    mysql_virtual_alias_domain_maps.cf \
    mysql_virtual_alias_maps.cf mysql_virtual_domains_maps.cf \
    mysql_virtual_mailbox_maps.cf \
    /etc/postfix/sql/
COPY start.sh /start.sh
RUN newaliases
RUN ${PKG_REMOVE} apk-tools

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