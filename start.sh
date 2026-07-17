#!/bin/sh -e

# Add a milter to smtpd_milters / non_smtpd_milters (appends if already set)
_add_milter() {
    local addr="$1"
    if postconf smtpd_milters 2>/dev/null | grep -qF "inet:${addr}"; then
        return  # already configured
    fi
    local cur
    cur=$(postconf -h smtpd_milters 2>/dev/null)
    if [ -z "${cur}" ]; then
        postconf -e "smtpd_milters=inet:${addr}"
        postconf -e "non_smtpd_milters=inet:${addr}"
    else
        postconf -e "smtpd_milters=${cur}, inet:${addr}"
        local cur_non
        cur_non=$(postconf -h non_smtpd_milters 2>/dev/null)
        postconf -e "non_smtpd_milters=${cur_non:+${cur_non}, }inet:${addr}"
    fi
    postconf -e "milter_default_action=accept"
    postconf -e "milter_protocol=6"
}

# Rspamd milter — one single upstream that covers DKIM signing + DKIM
# verify + DMARC + SPF + greylist + Bayes-based spam scoring + ClamAV.
# RSPAMD=host or RSPAMD=host:port (default port 11332).
if [ -n "${RSPAMD}" ] && [ "${RSPAMD}" = "${RSPAMD%:*}" ]; then
    RSPAMD="${RSPAMD}:11332"
fi
if [ -n "${RSPAMD}" ]; then
    _add_milter "${RSPAMD}"
    echo "**** Rspamd milter configured: ${RSPAMD}"
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
    postconf -e "smtpd_tls_auth_only = no"
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

if [ -n "${DISABLE_DNSBL}" ]; then
    postconf -e "smtpd_client_restrictions=permit_sasl_authenticated"
    postconf -e "smtpd_helo_restrictions=permit_sasl_authenticated, permit_mynetworks, reject_non_fqdn_hostname, reject_unauth_pipelining"
    postconf -e "smtpd_recipient_restrictions=permit_sasl_authenticated, permit_mynetworks, reject_unknown_recipient_domain, reject_non_fqdn_recipient, reject_unauth_pipelining"
    postconf -e "smtpd_relay_restrictions=permit_sasl_authenticated, reject_unknown_recipient_domain, reject_non_fqdn_recipient, reject_unauth_pipelining, reject_unauth_destination"
    echo "**** DNSBL/RBL checks disabled"
fi

# SPF policy check on incoming mail (disabled by setting CHECK_SPF=no).
# When RSPAMD is configured, rspamd's SPF module handles this — running
# policyd-spf in parallel duplicates the work and can produce
# contradictory verdicts. Auto-disable in that case.
if [ -n "${RSPAMD}" ] && [ -z "${CHECK_SPF+set}" ]; then
    CHECK_SPF="no"
fi
if [ "${CHECK_SPF}" != "no" ] && command -v postfix-policyd-spf-perl >/dev/null 2>&1; then
    if ! postconf smtpd_recipient_restrictions | grep -q "policy-spf"; then
        cur=$(postconf -h smtpd_recipient_restrictions 2>/dev/null)
        postconf -e "smtpd_recipient_restrictions=${cur}, check_policy_service unix:private/policy-spf"
        echo "**** SPF policy check enabled"
    fi
fi

if [ -n "${MYNETWORKS}" ]; then
    postconf -e "mynetworks=${MYNETWORKS}"
    echo "**** mynetworks restricted to ${MYNETWORKS}"
fi

postconf -e "myhostname=${HOSTNAME:-$DOMAIN}"
postconf -e "mydomain=${DOMAIN}"
#postconf -e "mydestination=$LOCAL_DOMAINS"

if [ -n "${RELAYHOST}" ]; then
    postconf -e "relayhost=[${RELAYHOST}]"
    echo "**** All outbound mail relayed through ${RELAYHOST}"
fi

/usr/sbin/postfix start-fg
