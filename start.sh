/bin/sh -e

# greylist filter use GREYLIST=host:port or --link greylist-container:postgrey
if test -n "${GREYLIST}" && ! postconf smtpd_client_restrictions | grep -q "inet:${GREYLIST}:10023"; then
    postconf -e "$(postconf smtpd_client_restrictions), check_policy_service inet:${GREYLIST}:10023"
    echo "**** Greylisting configured to use ${GREYLIST}:10023"

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
    echo "**** TLS configured for ${HOSTNAME:-$DOMAIN}}"
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

/usr/sbin/postfix start-fg
