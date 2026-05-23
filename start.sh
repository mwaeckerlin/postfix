#!/bin/bash -e

# greylisting milter use GREYLIST=host:port or GREYLIST=host (default port)
if [[ -n "${GREYLIST}" && "${GREYLIST}" != *:* ]]; then
    GREYLIST="${GREYLIST}:10025"
fi
if [[ -n "${GREYLIST}" && ! "$(postconf smtpd_milters)" =~ "inet:${GREYLIST}" ]]; then
    postconf -e "smtpd_milters=inet:${GREYLIST}"
    postconf -e "non_smtpd_milters=inet:${GREYLIST}"
    postconf -e "milter_default_action=accept"
    postconf -e "milter_protocol=6"
    echo "**** Greylisting milter configured to use ${GREYLIST}"

fi

# check if letsencrypt certificates exist
if test -e /etc/letsencrypt/live/${HOSTROOT:-${HOSTNAME:-$DOMAIN}}/fullchain.pem \
    -a -e /etc/letsencrypt/live/${HOSTROOT:-${HOSTNAME:-$DOMAIN}}/privkey.pem; then
    postconf -e "smtpd_tls_cert_file=/etc/letsencrypt/live/${HOSTROOT:-${HOSTNAME:-$DOMAIN}}/fullchain.pem"
    postconf -e "smtpd_tls_key_file=/etc/letsencrypt/live/${HOSTROOT:-${HOSTNAME:-$DOMAIN}}/privkey.pem"
    postconf -e "smtpd_use_tls=yes"
    postconf -e "smtpd_tls_security_level=may"
    postconf -e "smtpd_tls_auth_only = yes"
    postconf -e "smtpd_use_tls = yes"
    postconf -e "smtp_tls_note_starttls_offer = yes"
    echo "**** Status: TLS configured for ${HOSTNAME:-$DOMAIN} on /etc/letsencrypt/live/${HOSTROOT:-${HOSTNAME:-$DOMAIN}}"
else
    echo "#### WARNING! Status: TLS NOT configured for ${HOSTNAME:-$DOMAIN} on /etc/letsencrypt/live/${HOSTROOT:-${HOSTNAME:-$DOMAIN}}"
fi

SQL_CONFIGS="
    /etc/postfix/sql/mysql_virtual_alias_domain_catchall_maps.cf
    /etc/postfix/sql/mysql_virtual_alias_domain_mailbox_maps.cf
    /etc/postfix/sql/mysql_virtual_alias_domain_maps.cf
    /etc/postfix/sql/mysql_virtual_alias_maps.cf
    /etc/postfix/sql/mysql_virtual_domains_maps.cf
    /etc/postfix/sql/mysql_virtual_mailbox_maps.cf
"
for f in $SQL_CONFIGS; do
    sed -i '/^query/!d' $f
done
cat | tee -a $SQL_CONFIGS <<END
user     = ${DB_USER}
password = ${DB_PASSWORD}
hosts    = ${DB_HOST}
dbname   = ${DB_NAME}
END
for f in $SQL_CONFIGS; do
    sed -i '/^query/{hd};${pg}' $f
done

postconf -e "myhostname=${HOSTNAME:-$DOMAIN}"
postconf -e "mydomain=${DOMAIN}"
#postconf -e "mydestination=$LOCAL_DOMAINS"

if [[ -n "${RELAYHOST}" ]]; then
    postconf -e "relayhost=[${RELAYHOST}]"
    echo "**** All outbound mail relayed through ${RELAYHOST}"
fi

/usr/sbin/postfix start-fg
