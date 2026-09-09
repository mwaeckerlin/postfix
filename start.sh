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

# Greylisting milter: GREYLIST=host:port or GREYLIST=host (default port 10025)
if [ -n "${GREYLIST}" ] && [ "${GREYLIST}" = "${GREYLIST%:*}" ]; then
    GREYLIST="${GREYLIST}:10025"
fi
if [ -n "${GREYLIST}" ]; then
    _add_milter "${GREYLIST}"
    echo "**** Greylisting milter configured: ${GREYLIST}"
fi

# DKIM milter: OPENDKIM=host:port or OPENDKIM=host (default port 10026)
if [ -n "${OPENDKIM}" ] && [ "${OPENDKIM}" = "${OPENDKIM%:*}" ]; then
    OPENDKIM="${OPENDKIM}:10026"
fi
if [ -n "${OPENDKIM}" ]; then
    _add_milter "${OPENDKIM}"
    echo "**** OpenDKIM milter configured: ${OPENDKIM}"
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

# SPF policy check on incoming mail (disabled by setting CHECK_SPF=no)
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

# The queue is a persistent volume, so master.pid survives a container
# replacement: postfix start-fg then reads a PID from the previous
# container, believes the mail system is already running and aborts with
# "fatal: the Postfix mail system is already running". A PID inside this
# container's namespace either belongs to a live process or to nothing at
# all, so the stale file is removed unless that exact PID is alive here.
PIDFILE="$(postconf -h queue_directory)/pid/master.pid"
if [ -f "${PIDFILE}" ]; then
    STALE_PID="$(cat "${PIDFILE}" 2>/dev/null | tr -dc '0-9')"
    if [ -n "${STALE_PID}" ] && [ -d "/proc/${STALE_PID}" ]; then
        echo "**** Postfix already running as PID ${STALE_PID}"
    else
        rm -f "${PIDFILE}"
        echo "**** Removed stale ${PIDFILE} (PID ${STALE_PID:-unknown} is not running)"
    fi
fi

/usr/sbin/postfix start-fg
