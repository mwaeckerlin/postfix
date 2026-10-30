#!/usr/bin/env bash
# Environment contract: every operator setting reaches the effective
# postfix configuration — the image default when the variable is unset,
# the operator's value when it is set.
#
# Each case starts the image with its environment, waits until init has
# configured postfix and the master listens (the --healthcheck probe
# answers), and reads the effective value with `postconf -h` — or, for
# the sql maps, the rendered map file — inside the running container.
# `--network none` keeps the container off every network (no database,
# milter or dovecot is contacted at start-up); `--pull=never` tests the
# local build.
#
# Usage: tests/env-config.sh IMAGE

set -uo pipefail

IMAGE="${1:-mwaeckerlin/postfix}"

PASS=0
FAIL=0
declare -a FAILED_NAMES
declare -a CONTAINERS

_pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
_fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "  FAIL  $1: $2"; }

_cleanup() {
    [[ ${#CONTAINERS[@]} -gt 0 ]] && docker rm -f "${CONTAINERS[@]}" > /dev/null 2>&1
}
trap _cleanup EXIT

_image_exists() {
    if docker image inspect "${IMAGE}" > /dev/null 2>&1; then
        return 0
    fi
    _fail "image_exists" "image not built — run 'npm run build' first"
    return 1
}

# Start the image with the given docker arguments; sets CID once init is
# done and the SMTP listener answers, fails after 60 probes.
_start() {
    local name="$1" i
    shift
    CID=$(docker run -d --pull=never --network none \
              -e DOMAIN=example.com -e HOSTNAME=mail.example.com \
              -e DB_HOST=postfixadmin-db -e RSPAMD=rspamd \
              "$@" "${IMAGE}")
    CONTAINERS+=("${CID}")
    for i in $(seq 1 60); do
        if docker exec "${CID}" /usr/bin/init --healthcheck > /dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    _fail "${name}_started" "listener never came up: $(docker logs "${CID}" 2>&1)"
    return 1
}

_expect() {
    local name="$1" param="$2" want="$3" got
    got=$(docker exec "${CID}" /usr/sbin/postconf -h "${param}" 2>/dev/null)
    if [[ "${got}" == "${want}" ]]; then
        _pass "${name}"
    else
        _fail "${name}" "${param} = '${got}', expected '${want}'"
    fi
}

# The `hosts` line of every sql map the image renders from DB_HOST/DB_PORT.
_expect_sql_hosts() {
    local name="$1" want="$2" map got ok=1
    for map in mysql_virtual_alias_domain_catchall_maps mysql_virtual_alias_domain_mailbox_maps \
               mysql_virtual_alias_domain_maps mysql_virtual_alias_maps \
               mysql_virtual_domains_maps mysql_virtual_mailbox_maps; do
        got=$(docker cp "${CID}:/etc/postfix/sql/${map}.cf" - 2>/dev/null | tar -xO 2>/dev/null | grep '^hosts')
        if [[ "${got}" != "hosts    = ${want}" ]]; then
            _fail "${name}" "${map}.cf: '${got}', expected 'hosts    = ${want}'"
            ok=0
        fi
    done
    [[ ${ok} -eq 1 ]] && _pass "${name}"
}

# One line of the generated header_checks map. The map refuses mail
# during DATA, before the message is accepted, so what stands in it
# decides what the sending host is told.
_expect_header_check() {
    local name="$1" want="$2" got
    got=$(docker cp "${CID}:/etc/postfix/header_checks" - 2>/dev/null | tar -xO 2>/dev/null)
    if [[ "${got}" == *"${want}"* ]]; then
        _pass "${name}"
    else
        _fail "${name}" "header_checks has no line '${want}': ${got}"
    fi
}

_expect_no_header_check() {
    local name="$1" unwanted="$2" got
    got=$(docker cp "${CID}:/etc/postfix/header_checks" - 2>/dev/null | tar -xO 2>/dev/null)
    if [[ "${got}" == *"${unwanted}"* ]]; then
        _fail "${name}" "header_checks still carries '${unwanted}'"
    else
        _pass "${name}"
    fi
}

# One line of a map file the init wrote inside the container.
_expect_file_line() {
    local name="$1" path="$2" want="$3" got
    got=$(docker cp "${CID}:${path}" - 2>/dev/null | tar -xO 2>/dev/null)
    if [[ "${got}" == *"${want}"* ]]; then
        _pass "${name}"
    else
        _fail "${name}" "${path} has no line '${want}': ${got}"
    fi
}

# A map the image writes only when a switch asks for it.
_expect_no_file() {
    local name="$1" path="$2"
    if docker cp "${CID}:${path}" - > /dev/null 2>&1; then
        _fail "${name}" "${path} exists although nothing asked for it"
    else
        _pass "${name}"
    fi
}

RECIPIENT_BASE="permit_sasl_authenticated, permit_mynetworks, reject_unknown_recipient_domain, reject_non_fqdn_recipient, reject_unauth_pipelining"
RELAY_BASE="permit_sasl_authenticated, reject_unknown_recipient_domain, reject_non_fqdn_recipient, reject_unauth_pipelining, reject_unauth_destination"

echo "==> Environment contract: settings reach the effective configuration"

_image_exists || { echo ""; echo "==> Environment contract results: 0 passed, 1 failed"; exit 1; }

if _start defaults; then
    _expect default_virtual_transport virtual_transport "lmtp:inet:dovecot:24"
    _expect default_mailbox_transport mailbox_transport "lmtp:inet:dovecot:24"
    _expect default_sasl_path         smtpd_sasl_path   "inet:dovecot:12345"
    _expect default_milter_action     milter_default_action "accept"
    _expect default_dnsbl_recipient smtpd_recipient_restrictions \
        "${RECIPIENT_BASE}, reject_multi_recipient_bounce, reject_rbl_client ix.dnsbl.manitu.net=127.0.0.[2..11], reject_rbl_client sbl.spamhaus.org=127.0.0.[2..11], reject_rbl_client xbl.spamhaus.org=127.0.0.[2..11]"
    _expect default_dnsbl_relay smtpd_relay_restrictions \
        "${RELAY_BASE}, reject_rbl_client ix.dnsbl.manitu.net=127.0.0.[2..11], reject_rbl_client sbl.spamhaus.org=127.0.0.[2..11], reject_rbl_client xbl.spamhaus.org=127.0.0.[2..11]"
    _expect default_rhsbl_client smtpd_client_restrictions \
        "permit_sasl_authenticated, reject_invalid_hostname, reject_rhsbl_sender dbl.spamhaus.org=127.0.1.[2..99], reject_rhsbl_client dbl.spamhaus.org=127.0.1.[2..99], reject_rhsbl_helo dbl.spamhaus.org=127.0.1.[2..99]"
    _expect_sql_hosts default_db_port "postfixadmin-db"
    # The relay images this one builds on let the private networks relay
    # without a password. A mail server that inherits that is an open
    # relay towards every container of a swarm, whose overlay networks
    # live in 10.0.0.0/8.
    _expect default_mynetworks mynetworks "127.0.0.1/32"
fi

if _start mynetworks_override -e MYNETWORKS="10.1.0.0/16, 127.0.0.0/8"; then
    _expect override_mynetworks mynetworks "10.1.0.0/16, 127.0.0.0/8"
fi

if _start override \
       -e DOVECOT_HOST=imap.internal \
       -e DOVECOT_LMTP_PORT=2424 \
       -e DOVECOT_SASL_PORT=23456 \
       -e MILTER_DEFAULT_ACTION=tempfail \
       -e DNSBL_SERVERS="bl.example.org zen.example.org" \
       -e RHSBL_SERVERS=dbl.example.org \
       -e DB_PORT=3307 \
       -e RELAYHOST=relay.example.com:587; then
    _expect override_virtual_transport virtual_transport "lmtp:inet:imap.internal:2424"
    _expect override_mailbox_transport mailbox_transport "lmtp:inet:imap.internal:2424"
    _expect override_sasl_path         smtpd_sasl_path   "inet:imap.internal:23456"
    _expect override_milter_action     milter_default_action "tempfail"
    _expect override_dnsbl_recipient smtpd_recipient_restrictions \
        "${RECIPIENT_BASE}, reject_multi_recipient_bounce, reject_rbl_client bl.example.org, reject_rbl_client zen.example.org"
    _expect override_dnsbl_relay smtpd_relay_restrictions \
        "${RELAY_BASE}, reject_rbl_client bl.example.org, reject_rbl_client zen.example.org"
    _expect override_rhsbl_client smtpd_client_restrictions \
        "permit_sasl_authenticated, reject_invalid_hostname, reject_rhsbl_sender dbl.example.org, reject_rhsbl_client dbl.example.org, reject_rhsbl_helo dbl.example.org"
    _expect_sql_hosts override_db_port "postfixadmin-db:3307"
    _expect override_relayhost relayhost "[relay.example.com]:587"
fi

if _start dnsbl_return_codes -e DNSBL_SERVERS="bl.example.org=127.0.0.[2..11]"; then
    _expect dnsbl_return_codes smtpd_recipient_restrictions \
        "${RECIPIENT_BASE}, reject_multi_recipient_bounce, reject_rbl_client bl.example.org=127.0.0.[2..11]"
fi

if _start disable_dnsbl_wins -e DISABLE_DNSBL=1 -e DNSBL_SERVERS=bl.example.org; then
    _expect disable_dnsbl_wins smtpd_recipient_restrictions "${RECIPIENT_BASE}, reject_multi_recipient_bounce"
fi

# Plausibility of the envelope. The checks that reject on the client's
# own DNS are off by default — a sender without a reverse record is a
# legitimate sender — and an empty envelope sender stays accepted,
# because RFC 5321 gives a bounce exactly that.
if _start plausibility_defaults; then
    _expect default_sender_domain smtpd_sender_restrictions \
        "permit_sasl_authenticated, permit_mynetworks, reject_non_fqdn_sender, reject_unauth_pipelining, reject_unknown_sender_domain"
    _expect default_unlisted_recipient smtpd_reject_unlisted_recipient "yes"
    _expect default_delay_reject       smtpd_delay_reject              "yes"
    _expect default_vrfy_disabled      disable_vrfy_command            "yes"
    _expect default_client_dns smtpd_client_restrictions "permit_sasl_authenticated, reject_invalid_hostname, reject_rhsbl_sender dbl.spamhaus.org=127.0.1.[2..99], reject_rhsbl_client dbl.spamhaus.org=127.0.1.[2..99], reject_rhsbl_helo dbl.spamhaus.org=127.0.1.[2..99]"
    _expect_no_file default_no_sender_access /etc/postfix/sender_access
fi

if _start plausibility_off \
       -e REJECT_UNKNOWN_SENDER_DOMAIN=no \
       -e REJECT_MULTI_RECIPIENT_BOUNCE=no \
       -e REJECT_UNLISTED_RECIPIENT=no \
       -e SMTPD_DELAY_REJECT=no \
       -e DISABLE_VRFY_COMMAND=no; then
    _expect off_sender_domain smtpd_sender_restrictions "permit_sasl_authenticated, permit_mynetworks, reject_non_fqdn_sender, reject_unauth_pipelining"
    _expect off_recipient smtpd_recipient_restrictions \
        "${RECIPIENT_BASE}, reject_rbl_client ix.dnsbl.manitu.net=127.0.0.[2..11], reject_rbl_client sbl.spamhaus.org=127.0.0.[2..11], reject_rbl_client xbl.spamhaus.org=127.0.0.[2..11]"
    _expect off_unlisted_recipient smtpd_reject_unlisted_recipient "no"
    _expect off_delay_reject       smtpd_delay_reject              "no"
    _expect off_vrfy_disabled      disable_vrfy_command            "no"
fi

# Both checks stand in front of the blocklist lookups: an envelope
# check costs nothing, a blocklist lookup costs a DNS query.
if _start plausibility_client_dns \
       -e REJECT_UNKNOWN_REVERSE_CLIENT_HOSTNAME=yes \
       -e REJECT_UNKNOWN_CLIENT_HOSTNAME=yes; then
    _expect on_client_dns smtpd_client_restrictions "permit_sasl_authenticated, reject_invalid_hostname, reject_unknown_reverse_client_hostname, reject_unknown_client_hostname, reject_rhsbl_sender dbl.spamhaus.org=127.0.1.[2..99], reject_rhsbl_client dbl.spamhaus.org=127.0.1.[2..99], reject_rhsbl_helo dbl.spamhaus.org=127.0.1.[2..99]"
fi

if _start empty_sender_rejected -e REJECT_EMPTY_SENDER=yes; then
    _expect empty_sender_restriction smtpd_sender_restrictions \
        "permit_sasl_authenticated, permit_mynetworks, reject_non_fqdn_sender, reject_unauth_pipelining, reject_unknown_sender_domain, check_sender_access regexp:/etc/postfix/sender_access"
    _expect_file_line empty_sender_map /etc/postfix/sender_access \
        "REJECT Empty envelope sender not accepted"
fi

if _start empty_sender_text -e REJECT_EMPTY_SENDER=yes \
       -e REJECT_EMPTY_SENDER_TEXT="Please name a sender"; then
    _expect_file_line empty_sender_own_text /etc/postfix/sender_access \
        "REJECT Please name a sender"
fi

# Subject rules: both on by default, each switchable, each with its own
# text. The first line of the map exempts a MIME-encoded subject,
# because Postfix matches the raw header and never decodes RFC 2047.
if _start header_checks_defaults; then
    _expect header_checks_default_map header_checks "regexp:/etc/postfix/header_checks"
    _expect_header_check header_checks_default_mime \
        '/^Subject:[[:space:]]*=\?/   DUNNO'
    _expect_header_check header_checks_default_shouting \
        '/^Subject:[^a-z]*[A-Z][^a-z]*$/   REJECT Subject does not seem to be reasonable, looks like SPAM'
    _expect_header_check header_checks_default_empty \
        '/^Subject:[[:space:]]*$/   REJECT Empty subject not accepted, please specify a subject'
fi

if _start header_checks_texts \
       -e REJECT_SHOUTING_SUBJECT_TEXT="Please do not shout" \
       -e REJECT_EMPTY_SUBJECT_TEXT="A subject is required"; then
    _expect_header_check header_checks_shouting_text \
        'REJECT Please do not shout'
    _expect_header_check header_checks_empty_text \
        'REJECT A subject is required'
fi

if _start header_checks_one_off -e REJECT_EMPTY_SUBJECT=no; then
    _expect header_checks_one_off_map header_checks "regexp:/etc/postfix/header_checks"
    _expect_header_check header_checks_one_off_shouting \
        '/^Subject:[^a-z]*[A-Z][^a-z]*$/'
    _expect_no_header_check header_checks_one_off_empty \
        '/^Subject:[[:space:]]*$/'
fi

if _start header_checks_both_off \
       -e REJECT_SHOUTING_SUBJECT=no -e REJECT_EMPTY_SUBJECT=no; then
    _expect header_checks_both_off header_checks ""
fi

echo ""
echo "==> Environment contract results: ${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -gt 0 ]]; then
    echo "==> Failed checks: ${FAILED_NAMES[*]}"
    exit 1
fi
