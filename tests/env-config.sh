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
        "${RECIPIENT_BASE}, reject_rbl_client ix.dnsbl.manitu.net, reject_rbl_client sbl.spamhaus.org, reject_rbl_client xbl.spamhaus.org"
    _expect default_dnsbl_relay smtpd_relay_restrictions \
        "${RELAY_BASE}, reject_rbl_client ix.dnsbl.manitu.net, reject_rbl_client sbl.spamhaus.org, reject_rbl_client xbl.spamhaus.org"
    _expect default_rhsbl_client smtpd_client_restrictions \
        "permit_sasl_authenticated, reject_invalid_hostname, reject_rhsbl_sender dbl.spamhaus.org, reject_rhsbl_client dbl.spamhaus.org, reject_rhsbl_helo dbl.spamhaus.org"
    _expect_sql_hosts default_db_port "postfixadmin-db"
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
        "${RECIPIENT_BASE}, reject_rbl_client bl.example.org, reject_rbl_client zen.example.org"
    _expect override_dnsbl_relay smtpd_relay_restrictions \
        "${RELAY_BASE}, reject_rbl_client bl.example.org, reject_rbl_client zen.example.org"
    _expect override_rhsbl_client smtpd_client_restrictions \
        "permit_sasl_authenticated, reject_invalid_hostname, reject_rhsbl_sender dbl.example.org, reject_rhsbl_client dbl.example.org, reject_rhsbl_helo dbl.example.org"
    _expect_sql_hosts override_db_port "postfixadmin-db:3307"
    _expect override_relayhost relayhost "[relay.example.com]:587"
fi

if _start disable_dnsbl_wins -e DISABLE_DNSBL=1 -e DNSBL_SERVERS=bl.example.org; then
    _expect disable_dnsbl_wins smtpd_recipient_restrictions "${RECIPIENT_BASE}"
fi

echo ""
echo "==> Environment contract results: ${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -gt 0 ]]; then
    echo "==> Failed checks: ${FAILED_NAMES[*]}"
    exit 1
fi
