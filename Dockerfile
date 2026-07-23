# Inherits the accumulated postfix configuration (main.cf) from the
# published mwaeckerlin/mailforward image (which in turn layers on
# mwaeckerlin/smtp-relay) — a locally built image takes precedence,
# otherwise Docker pulls it from the hub. The build stage installs
# postfix fresh (very-base has the package manager the headless parent
# no longer ships) and layers this image's deltas on the parent's
# main.cf.
FROM mwaeckerlin/mailforward AS parent

FROM mwaeckerlin/very-base AS init
RUN $PKG_INSTALL g++
COPY init.cpp .
RUN g++ -static -Os -flto=auto -fno-rtti -ffunction-sections -fdata-sections \
        -Wl,--gc-sections -Wl,-s -std=c++20 -o init init.cpp
RUN strip -s -R .comment -R .gnu.version --strip-unneeded init

FROM mwaeckerlin/very-base AS build
# postfix-policyd-spf-perl is gone (headless: no perl): SPF is verified
# by rspamd's SPF module — the policy service duplicated the work and
# was auto-disabled whenever RSPAMD was set.
RUN $PKG_INSTALL postfix postfix-mysql postfix-pcre ca-certificates
RUN mkdir -p /tmp
RUN chmod 1777 /tmp
COPY --from=parent /etc/postfix/main.cf /etc/postfix/main.cf
RUN addgroup -g 5000 login-user
RUN adduser -H -D -u 5000 -G login-user login-user
RUN mkdir -p /var/mail/domains
RUN chown login-user:login-user /var/mail/domains
RUN postconf -e 'virtual_mailbox_domains = proxy:mysql:/etc/postfix/sql/mysql_virtual_domains_maps.cf'
RUN postconf -e 'virtual_alias_maps = proxy:mysql:/etc/postfix/sql/mysql_virtual_alias_maps.cf, proxy:mysql:/etc/postfix/sql/mysql_virtual_alias_domain_maps.cf, proxy:mysql:/etc/postfix/sql/mysql_virtual_alias_domain_catchall_maps.cf'
RUN postconf -e 'virtual_mailbox_maps = proxy:mysql:/etc/postfix/sql/mysql_virtual_mailbox_maps.cf, proxy:mysql:/etc/postfix/sql/mysql_virtual_alias_domain_mailbox_maps.cf'
RUN postconf -e 'virtual_gid_maps = static:5000'
RUN postconf -e 'virtual_uid_maps = static:5000'
RUN postconf -e 'virtual_minimum_uid = 100'
RUN postconf -e 'smtputf8_enable = no'
RUN postconf -e 'virtual_transport=lmtp:inet:dovecot'
RUN postconf -e 'mailbox_transport=lmtp:inet:dovecot'
RUN postconf -e 'local_transport = virtual'

# TLS handshake loglevels are set at start-up from POSTFIX_TLS_LOGLEVEL
# (default 0 — never bake a debug loglevel into a production image).

# SASL
RUN postconf -e 'broken_sasl_auth_clients = yes'
RUN postconf -e 'smtpd_sasl_auth_enable = yes'
RUN postconf -e 'smtpd_sasl_path = inet:dovecot:12345'
RUN postconf -e 'smtpd_sasl_type = dovecot'
RUN postconf -e 'smtpd_use_tls = no'
RUN postconf -e 'smtpd_sasl_security_options = noanonymous'

# Record the transport security of the receiving hop in our own
# Received: header (`(using TLSv1.3 with cipher …)` — or nothing when
# the peer delivered in the clear). Adding a header never breaks a DKIM
# signature (signatures only cover the headers the signer listed).
RUN postconf -e 'smtpd_tls_received_header = yes'
# Hand the live session's TLS version and cipher to the rspamd milter
# (as macros) so rspamd can stamp the machine-readable
# X-Transport-Security header on every incoming mail — the trustworthy
# last-hop measurement, taken at our MX. See the rspamd README
# «Transport encryption transparency».
RUN postconf -e 'milter_mail_macros = i {auth_type} {auth_authen} {auth_author} {mail_addr} {mail_host} {mail_mailer} {tls_version} {cipher}'

# Dedicated submission services (RFC 6409 / RFC 8314), separate from the
# port-25 MX so each role gets its own policy: submission enforces TLS
# (encrypt) and SASL auth, with no MX/DNSBL restrictions for our own
# authenticated users. Port 25 stays opportunistic-TLS + anonymous for
# server-to-server mail. Both require a certificate; without one the
# submission listeners refuse every login (nothing to encrypt with).
#   587 = STARTTLS submission, 465 = implicit-TLS submission (smtps).
RUN postconf -M submission/inet='submission inet n - n - - smtpd'
RUN postconf -P submission/inet/syslog_name=postfix/submission
RUN postconf -P submission/inet/smtpd_tls_security_level=encrypt
RUN postconf -P submission/inet/smtpd_sasl_auth_enable=yes
RUN postconf -P submission/inet/smtpd_tls_auth_only=yes
RUN postconf -P submission/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject
RUN postconf -P submission/inet/smtpd_relay_restrictions=permit_sasl_authenticated,reject
RUN postconf -M smtps/inet='smtps inet n - n - - smtpd'
RUN postconf -P smtps/inet/syslog_name=postfix/smtps
RUN postconf -P smtps/inet/smtpd_tls_wrappermode=yes
RUN postconf -P smtps/inet/smtpd_sasl_auth_enable=yes
RUN postconf -P smtps/inet/smtpd_tls_auth_only=yes
RUN postconf -P smtps/inet/smtpd_client_restrictions=permit_sasl_authenticated,reject
RUN postconf -P smtps/inet/smtpd_relay_restrictions=permit_sasl_authenticated,reject

# message_size_limit and smtpd_hard_error_limit are set at start-up
# from the MESSAGE_SIZE_LIMIT / SMTP_HARD_ERROR_LIMIT env (see
# init.cpp) so they stay configurable with high, delivery-safe
# defaults.

# antispam
RUN postconf -e 'smtpd_helo_required = yes'
RUN postconf -e 'smtpd_helo_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_invalid_hostname, reject_non_fqdn_hostname, reject_unauth_pipelining'
RUN postconf -e 'smtpd_sender_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_non_fqdn_sender, reject_unauth_pipelining'
RUN postconf -e 'smtpd_recipient_restrictions = permit_sasl_authenticated, permit_mynetworks, reject_unknown_recipient_domain, reject_non_fqdn_recipient, reject_unauth_pipelining, reject_rbl_client ix.dnsbl.manitu.net, reject_rbl_client sbl.spamhaus.org, reject_rbl_client xbl.spamhaus.org'
RUN postconf -e 'smtpd_client_restrictions = permit_sasl_authenticated, reject_invalid_hostname, reject_rhsbl_sender dbl.spamhaus.org, reject_rhsbl_client dbl.spamhaus.org, reject_rhsbl_helo dbl.spamhaus.org'
RUN postconf -e 'smtpd_relay_restrictions = permit_sasl_authenticated, reject_unknown_recipient_domain, reject_non_fqdn_recipient, reject_unauth_pipelining, reject_unauth_destination, reject_rbl_client ix.dnsbl.manitu.net, reject_rbl_client sbl.spamhaus.org, reject_rbl_client xbl.spamhaus.org'

COPY --chown=root:postfix \
    mysql_virtual_alias_domain_catchall_maps.cf \
    mysql_virtual_alias_domain_mailbox_maps.cf \
    mysql_virtual_alias_domain_maps.cf \
    mysql_virtual_alias_maps.cf mysql_virtual_domains_maps.cf \
    mysql_virtual_mailbox_maps.cf \
    /etc/postfix/sql/
# master execs every service directly — no chroot jail exists in the
# headless image, so normalize all master.cf entries to chroot=n.
RUN postconf -F '*/*/chroot=n'
RUN newaliases
COPY --from=init init /usr/bin/init
# These are shell scripts driven by the postfix(1) wrapper — the
# headless image boots master directly via init, so they must not ship.
RUN rm -f /usr/libexec/postfix/postfix-script \
          /usr/libexec/postfix/post-install \
          /usr/libexec/postfix/postfix-wrapper \
          /usr/libexec/postfix/postfix-tls-script \
          /usr/libexec/postfix/postmulti-script

# Collect only the binaries, shared libraries and configs the runtime
# actually needs into /root/ — no shell, no package manager, no
# busybox, no perl. musl's `ldd` accepts exactly ONE file per
# invocation, so deps are gathered in a per-file loop (this also pulls
# libmariadb for the mysql map type); /lib/ld-musl-x86_64.so.1 is the
# ELF interpreter and listed explicitly.
RUN tar cph \
        /etc/postfix /var/spool/postfix /var/lib/postfix /var/mail/domains \
        /etc/passwd /etc/group /etc/services /etc/nsswitch.conf \
        /etc/ssl/certs /etc/ssl/cert.pem /usr/share/ca-certificates \
        /usr/sbin/postconf /usr/sbin/postmap /usr/sbin/postalias \
        /usr/sbin/postsuper /usr/sbin/postlog /usr/sbin/postqueue \
        /usr/sbin/postdrop /usr/sbin/postcat /usr/sbin/sendmail \
        /usr/libexec/postfix /usr/lib/postfix \
        /usr/share/icu \
        /usr/bin/init /lib/ld-musl-x86_64.so.1 /tmp \
        $(for f in /usr/sbin/post* /usr/sbin/sendmail \
                   /usr/libexec/postfix/* /usr/lib/postfix/*.so*; do \
              ldd "$f" 2>/dev/null | sed -n 's,.* => \([^ ]*\) .*,\1,p'; \
          done | sort -u) \
    | tar xpC /root/

FROM mwaeckerlin/scratch
ENV CONTAINERNAME="postfix" \
    DB_USER="" \
    DB_PASSWORD="" \
    DB_HOST="" \
    DB_NAME="" \
    HOSTROOT="" \
    HOSTNAME="" \
    DOMAIN="" \
    RSPAMD="" \
    MYNETWORKS="" \
    RELAYHOST="" \
    DISABLE_DNSBL=""
# Delivery-affecting limits — high, configurable defaults (see
# init.cpp). MESSAGE_SIZE_LIMIT in bytes (0 = unlimited); default
# 100 GiB so even several photos/videos in one mail are accepted.
ENV MESSAGE_SIZE_LIMIT="107374182400" \
    SMTP_HARD_ERROR_LIMIT="20"
# TLS handshake logging (0 = production default, 2 = handshake debug —
# diagnostics override for test stacks).
ENV POSTFIX_TLS_LOGLEVEL="0"
# Without a TLS certificate SASL auth is disabled entirely (stack
# invariant: passwords never travel unencrypted). Set to "yes" only for
# a deliberately TLS-less deployment on an isolated network.
ENV POSTFIX_ALLOW_CLEARTEXT_AUTH="no"
# Opt-in: require TLS on the port-25 MX too (security_level=encrypt) —
# every inbound connection must negotiate TLS 1.2+ or the mail is
# rejected. Deliberately RFC-3207-non-compliant for a public MX; fit
# for internal / closed / B2B ingresses. Needs a certificate.
ENV SMTPD_TLS_REQUIRED="no"
# 25 = MX (server-to-server), 587 = STARTTLS submission,
# 465 = implicit-TLS submission (smtps).
EXPOSE 25 587 465
# Trade-off: the postfix master process must start as root to bind
# port 25 and manage the queue; every service then drops privileges to
# the postfix user per master.cf. See README.
USER root
ENTRYPOINT ["/usr/bin/init"]
VOLUME /var/mail/domains
# The mail queue MUST be persistent: postfix answers 250 as soon as a
# mail is fsync'ed into the queue — from then on the server owns
# delivery and the sender never retries. A deferred mail sitting here
# through a container recreate would otherwise vanish silently. Map
# this to a NAMED volume in production (an anonymous one does not
# survive `down`).
VOLUME /var/spool/postfix
COPY --from=build /root/ /
