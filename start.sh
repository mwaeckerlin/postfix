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

# DMARC milter: OPENDMARC=host:port or OPENDMARC=host (default port 8893).
# Added AFTER opendkim so opendmarc can consume opendkim's
# `Authentication-Results: … dkim=…` header when deciding DMARC alignment.
if [ -n "${OPENDMARC}" ] && [ "${OPENDMARC}" = "${OPENDMARC%:*}" ]; then
    OPENDMARC="${OPENDMARC}:8893"
fi
if [ -n "${OPENDMARC}" ]; then
    _add_milter "${OPENDMARC}"
    echo "**** OpenDMARC milter configured: ${OPENDMARC}"
fi

# check if letsencrypt certificates exist
if test -e /etc/letsencrypt/live/${HOSTROOT:-${HOSTNAME:-$DOMAIN}}/fullchain.pem \
    -a -e /etc/letsencrypt/live/${HOSTROOT:-${HOSTNAME:-$DOMAIN}}/privkey.pem; then
    postconf -e "smtpd_tls_cert_file=/etc/letsencrypt/live/${HOSTROOT:-${HOSTNAME:-$DOMAIN}}/fullchain.pem"
    postconf -e "smtpd_tls_key_file=/etc/letsencrypt/live/${HOSTROOT:-${HOSTNAME:-$DOMAIN}}/privkey.pem"
    postconf -e "smtpd_tls_security_level=may"
    postconf -e "smtpd_tls_auth_only = yes"
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

# Plausibility of the envelope, each check a switch. Every one of them
# goes in FRONT of the blocklist lookups of its list: a check on the
# envelope costs nothing, a blocklist lookup costs a DNS query, and
# postfix stops at the first check that rejects.
#
# The three that reject on the client's own DNS are off by default: a
# sender whose provider keeps no reverse record is a legitimate sender,
# and the big providers accept him too. An empty envelope sender stays
# accepted as well, because RFC 5321 gives a bounce exactly that, so a
# stack that refuses it never learns that its own mail bounced.

# Every SMTP text below is rendered into a line of a map file, so a
# newline in it would add a rule of its own: the start stops instead.
check_text() {
    eval "value=\${$1:-}"
    case "${value}" in
        *"
"*) echo "**** ERROR: invalid $1 — refusing to start" >&2; exit 1 ;;
    esac
}
check_text REJECT_SHOUTING_SUBJECT_TEXT
check_text REJECT_EMPTY_SUBJECT_TEXT
check_text REJECT_EMPTY_SENDER_TEXT

SENDER_ACCESS=/etc/postfix/sender_access
REJECT_UNKNOWN_SENDER_DOMAIN="${REJECT_UNKNOWN_SENDER_DOMAIN:-yes}"
REJECT_MULTI_RECIPIENT_BOUNCE="${REJECT_MULTI_RECIPIENT_BOUNCE:-yes}"
REJECT_UNLISTED_RECIPIENT="${REJECT_UNLISTED_RECIPIENT:-yes}"
SMTPD_DELAY_REJECT="${SMTPD_DELAY_REJECT:-yes}"
DISABLE_VRFY_COMMAND="${DISABLE_VRFY_COMMAND:-yes}"
REJECT_UNKNOWN_REVERSE_CLIENT_HOSTNAME="${REJECT_UNKNOWN_REVERSE_CLIENT_HOSTNAME:-no}"
REJECT_UNKNOWN_CLIENT_HOSTNAME="${REJECT_UNKNOWN_CLIENT_HOSTNAME:-no}"
REJECT_EMPTY_SENDER="${REJECT_EMPTY_SENDER:-no}"
REJECT_EMPTY_SENDER_TEXT="${REJECT_EMPTY_SENDER_TEXT:-Empty envelope sender not accepted}"

# insert_restriction LIST CHECK: add CHECK to LIST once, before the
# first blocklist lookup of that list.
insert_restriction() {
    cur=$(postconf -h "$1" 2>/dev/null)
    case ", ${cur}," in
        *", $2,"*) return 0 ;;
    esac
    if [ -z "${cur}" ]; then
        postconf -e "$1=$2"
        return 0
    fi
    postconf -e "$1=$(echo "${cur}" | awk -v check="$2" '
        BEGIN { RS = ","; placed = 0 }
        {
            gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", $0)
            if ($0 == "") next
            kind = $1
            if (!placed && (kind == "reject_rbl_client" ||
                            kind ~ /^reject_rhsbl_/)) {
                out = out sep check; sep = ", "; placed = 1
            }
            out = out sep $0; sep = ", "
        }
        END { print (placed ? out : out sep check) }')"
}

if [ "${REJECT_UNKNOWN_SENDER_DOMAIN}" != "no" ]; then
    # A sender domain with neither an A nor an MX record cannot receive
    # the answer to its own mail. While DNS itself is unreachable
    # postfix answers 450, so a resolver outage defers the mail.
    insert_restriction smtpd_sender_restrictions reject_unknown_sender_domain
fi
if [ "${REJECT_MULTI_RECIPIENT_BOUNCE}" != "no" ]; then
    # A bounce carries exactly one recipient; several name a forged one.
    insert_restriction smtpd_recipient_restrictions reject_multi_recipient_bounce
fi
if [ "${REJECT_UNKNOWN_REVERSE_CLIENT_HOSTNAME}" = "yes" ]; then
    insert_restriction smtpd_client_restrictions reject_unknown_reverse_client_hostname
fi
if [ "${REJECT_UNKNOWN_CLIENT_HOSTNAME}" = "yes" ]; then
    insert_restriction smtpd_client_restrictions reject_unknown_client_hostname
fi
if [ "${REJECT_EMPTY_SENDER}" = "yes" ]; then
    {
        echo "# Written by start.sh from REJECT_EMPTY_SENDER and"
        echo "# REJECT_EMPTY_SENDER_TEXT. Edits are overwritten on every"
        echo "# container start."
        echo ""
        echo "# smtpd_null_access_lookup_key: postfix looks the empty"
        echo "# envelope sender up as <>."
        echo "/^<>\$/   REJECT ${REJECT_EMPTY_SENDER_TEXT}"
    } > "${SENDER_ACCESS}"
    insert_restriction smtpd_sender_restrictions "check_sender_access regexp:${SENDER_ACCESS}"
fi

if [ "${REJECT_UNLISTED_RECIPIENT}" != "no" ]; then
    postconf -e "smtpd_reject_unlisted_recipient=yes"
else
    postconf -e "smtpd_reject_unlisted_recipient=no"
fi
if [ "${SMTPD_DELAY_REJECT}" != "no" ]; then
    postconf -e "smtpd_delay_reject=yes"
else
    postconf -e "smtpd_delay_reject=no"
fi
if [ "${DISABLE_VRFY_COMMAND}" != "no" ]; then
    postconf -e "disable_vrfy_command=yes"
else
    postconf -e "disable_vrfy_command=no"
fi
echo "**** plausibility: sender_domain=${REJECT_UNKNOWN_SENDER_DOMAIN}, multi_recipient_bounce=${REJECT_MULTI_RECIPIENT_BOUNCE}, unlisted_recipient=${REJECT_UNLISTED_RECIPIENT}, delay_reject=${SMTPD_DELAY_REJECT}, vrfy_disabled=${DISABLE_VRFY_COMMAND}, unknown_reverse_client=${REJECT_UNKNOWN_REVERSE_CLIENT_HOSTNAME}, unknown_client=${REJECT_UNKNOWN_CLIENT_HOSTNAME}, empty_sender_rejected=${REJECT_EMPTY_SENDER}"

# Two subject rules, evaluated by cleanup(8) during DATA, before the
# message is accepted. That is the only place in this image where a rule
# about the header refuses delivery without this server sending
# anything: the sending host keeps the message and its own provider
# informs the real sender.
#
# The first line exempts a MIME-encoded subject (RFC 2047). Postfix
# matches the raw header and never decodes it (header_checks(5), section
# BUGS), so a subject in Cyrillic, Arabic or Chinese, and a German one
# with umlauts, arrives as `=?UTF-8?B?…?=`. A rule about capital letters
# says nothing about base64.
#
# The shouting rule demands at least one capital Latin letter and no
# lowercase one. A subject in a script without capital letters carries
# no [A-Z] and is not matched.
HEADER_CHECKS=/etc/postfix/header_checks
REJECT_SHOUTING_SUBJECT="${REJECT_SHOUTING_SUBJECT:-yes}"
REJECT_EMPTY_SUBJECT="${REJECT_EMPTY_SUBJECT:-yes}"
REJECT_SHOUTING_SUBJECT_TEXT="${REJECT_SHOUTING_SUBJECT_TEXT:-Subject does not seem to be reasonable, looks like SPAM}"
REJECT_EMPTY_SUBJECT_TEXT="${REJECT_EMPTY_SUBJECT_TEXT:-Empty subject not accepted, please specify a subject}"
if [ "${REJECT_SHOUTING_SUBJECT}" = "no" ] && [ "${REJECT_EMPTY_SUBJECT}" = "no" ]; then
    postconf -e "header_checks="
    echo "**** subject header checks disabled"
else
    {
        echo "# Written by start.sh from REJECT_SHOUTING_SUBJECT,"
        echo "# REJECT_EMPTY_SUBJECT and their _TEXT variables. Edits are"
        echo "# overwritten on every container start."
        echo ""
        echo "# A MIME-encoded subject carries base64 or quoted-printable,"
        echo "# so no rule about letter case applies to it."
        echo '/^Subject:[[:space:]]*=\?/   DUNNO'
        if [ "${REJECT_SHOUTING_SUBJECT}" != "no" ]; then
            echo ""
            echo "# At least one capital Latin letter and no lowercase one."
            echo "/^Subject:[^a-z]*[A-Z][^a-z]*\$/   REJECT ${REJECT_SHOUTING_SUBJECT_TEXT}"
        fi
        if [ "${REJECT_EMPTY_SUBJECT}" != "no" ]; then
            echo ""
            echo "# A Subject header that is present and carries nothing."
            echo "/^Subject:[[:space:]]*\$/   REJECT ${REJECT_EMPTY_SUBJECT_TEXT}"
        fi
    } > "${HEADER_CHECKS}"
    postconf -e "header_checks=regexp:${HEADER_CHECKS}"
    echo "**** subject header checks: shouting=${REJECT_SHOUTING_SUBJECT}, empty=${REJECT_EMPTY_SUBJECT}"
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
