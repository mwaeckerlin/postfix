#!/usr/bin/env bash
# Image contract of the version line 1: the image keeps the configuration and
# the start-up behaviour this line has always had.
#
#   - `postfix check` accepts the configuration, and the settings of the line
#     stand in main.cf and master.cf: LMTP and SASL to dovecot, the MySQL maps,
#     the 1GB message limit, the SPF policy service
#   - started with a certificate, the database settings, the milters and a
#     stale master.pid from a previous container, start.sh removes the PID
#     file, renders the database settings into the maps, wires the milters and
#     the SPF check, and postfix answers on port 25 with STARTTLS
#   - postconf prints no warning about the configuration, neither in the
#     image nor after start.sh
#
# Nothing leaves the runner: the database, dovecot and the milters are named
# but never reached, the milters point at a closed local port.
#
# Usage: tests/image-contract.sh IMAGE

set -uo pipefail

# the last argument, so `npm test -- <image>` measures another image
IMAGE="${!#}"
NAME="postfix-contract-$$"
WORK="$(mktemp -d)"
PASS=0
FAIL=0
declare -a FAILED_NAMES

_pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
_fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "  FAIL  $1: $2"; }

_cleanup() {
    docker rm -f "${NAME}" "${NAME}-switched" > /dev/null 2>&1
    rm -rf "${WORK}"
}
trap _cleanup EXIT

# postconf prints the value on stdout and its warnings on stderr
_postconf() {
    docker run --rm --pull=never --entrypoint /usr/sbin/postconf "${IMAGE}" "$@" 2>/dev/null
}

_expect_setting() {
    local key="$1" expected="$2" actual
    actual="$(_postconf -h "${key}")"
    if [[ "${actual}" == "${expected}" ]]; then
        _pass "setting_${key}"
    else
        _fail "setting_${key}" "expected '${expected}', found '${actual}' / $(docker run --rm --pull=never --entrypoint /usr/sbin/postconf "${IMAGE}" -h "${key}" 2>&1)"
    fi
}

# one SMTP session: the greeting, then the answer to EHLO
_smtp_session() {
    local host="$1" port="$2" line
    exec 3<> "/dev/tcp/${host}/${port}" || return 1
    read -t 10 -r line <&3 || { exec 3<&-; return 1; }
    echo "${line}"
    printf 'EHLO contract.example.com\r\n' >&3
    while read -t 10 -r line <&3; do
        echo "${line}"
        [[ "${line}" == 250\ * ]] && break
    done
    printf 'QUIT\r\n' >&3
    exec 3<&-
}

echo "==> Image contract: ${IMAGE}"

if ! docker image inspect "${IMAGE}" > /dev/null 2>&1; then
    _fail "image_exists" "image not built — run 'npm run build' first"
    echo "==> Image contract results: ${PASS} passed, ${FAIL} failed"
    exit 1
fi

CHECK="$(docker run --rm --pull=never --entrypoint /usr/sbin/postfix "${IMAGE}" check 2>&1)"
if [[ $? -eq 0 ]]; then
    _pass "postfix_check"
else
    _fail "postfix_check" "${CHECK}"
fi

# postconf writes every warning about main.cf and master.cf to stderr
WARNINGS="$(docker run --rm --pull=never --entrypoint /usr/sbin/postconf "${IMAGE}" -n 2>&1 > /dev/null)"
if [[ -z "${WARNINGS}" ]]; then
    _pass "image_no_postconf_warnings"
else
    _fail "image_no_postconf_warnings" "postconf warns: ${WARNINGS}"
fi

# The relay images this one builds on let the private networks relay
# without a password, because that is what a relay is for. A mail server
# that inherits it is an open relay towards every container of a swarm,
# whose overlay networks live in 10.0.0.0/8. MYNETWORKS opens it again.
_expect_setting mynetworks "127.0.0.1/32"

_expect_setting virtual_transport "lmtp:inet:dovecot"
_expect_setting mailbox_transport "lmtp:inet:dovecot"
_expect_setting smtpd_sasl_type "dovecot"
_expect_setting smtpd_sasl_path "inet:dovecot:12345"
_expect_setting smtpd_sasl_auth_enable "yes"
_expect_setting message_size_limit "1073741824"
_expect_setting virtual_mailbox_domains "proxy:mysql:/etc/postfix/sql/mysql_virtual_domains_maps.cf"
_expect_setting virtual_uid_maps "static:5000"

SPF="$(_postconf -M policy-spf/unix)"
if [[ "${SPF}" == *"postfix-policyd-spf-perl"* ]]; then
    _pass "spf_policy_service"
else
    _fail "spf_policy_service" "master.cf has no policy-spf service: ${SPF}"
fi

mkdir -p "${WORK}/letsencrypt/live/mail.example.com"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=mail.example.com" \
    -keyout "${WORK}/letsencrypt/live/mail.example.com/privkey.pem" \
    -out "${WORK}/letsencrypt/live/mail.example.com/fullchain.pem" > /dev/null 2>&1

# the queue of a previous container leaves its master.pid behind
docker create --name "${NAME}" --pull=never -p 127.0.0.1::25 \
    -e HOSTNAME=mail.example.com -e DOMAIN=example.com \
    -e DB_HOST=db.example.com -e DB_NAME=postfix -e DB_USER=postfix -e DB_PASSWORD=contract-secret \
    -e GREYLIST=127.0.0.1 -e OPENDKIM=127.0.0.1 \
    --entrypoint /bin/sh "${IMAGE}" \
    -c 'mkdir -p "$(postconf -h queue_directory)/pid"; echo 4242 > "$(postconf -h queue_directory)/pid/master.pid"; exec /start.sh' \
    > /dev/null
docker cp "${WORK}/letsencrypt/." "${NAME}:/etc/letsencrypt" > /dev/null
docker start "${NAME}" > /dev/null

ADDRESS="$(docker port "${NAME}" 25/tcp)"
SESSION=""
for _ in $(seq 1 60); do
    SESSION="$(_smtp_session "${ADDRESS%:*}" "${ADDRESS##*:}" 2> /dev/null)"
    [[ "${SESSION}" == 220* ]] && break
    sleep 1
done
LOG="$(docker logs "${NAME}" 2>&1)"

if [[ "${SESSION}" == "220 mail.example.com"* ]]; then
    _pass "smtp_greeting"
else
    _fail "smtp_greeting" "no SMTP greeting from mail.example.com: ${SESSION:-nothing} / log: ${LOG}"
fi
if grep -q "^250.STARTTLS" <<< "${SESSION//$'\r'/}"; then
    _pass "smtp_starttls"
else
    _fail "smtp_starttls" "EHLO does not offer STARTTLS: ${SESSION}"
fi
if [[ "${LOG}" == *"Removed stale"*"master.pid"* ]]; then
    _pass "stale_pid_removed"
else
    _fail "stale_pid_removed" "start.sh did not remove the stale master.pid: ${LOG}"
fi
if [[ "${LOG}" == *"TLS configured for mail.example.com"* ]]; then
    _pass "tls_configured"
else
    _fail "tls_configured" "the certificate was not taken: ${LOG}"
fi

MAP="$(docker exec "${NAME}" cat /etc/postfix/sql/mysql_virtual_domains_maps.cf 2>&1)"
if grep -Eq '^hosts *= db.example.com$' <<< "${MAP}" && grep -Eq '^dbname *= postfix$' <<< "${MAP}" \
    && grep -Eq '^query' <<< "${MAP}"; then
    _pass "database_map_rendered"
else
    _fail "database_map_rendered" "${MAP}"
fi

MILTERS="$(docker exec "${NAME}" postconf -h smtpd_milters 2>&1)"
if [[ "${MILTERS}" == *"inet:127.0.0.1:10025"* && "${MILTERS}" == *"inet:127.0.0.1:10026"* ]]; then
    _pass "milters_default_ports"
else
    _fail "milters_default_ports" "${MILTERS}"
fi

RECIPIENT="$(docker exec "${NAME}" postconf -h smtpd_recipient_restrictions 2>&1)"
if [[ "${RECIPIENT}" == *"check_policy_service unix:private/policy-spf"* ]]; then
    _pass "spf_check_enabled"
else
    _fail "spf_check_enabled" "${RECIPIENT}"
fi


# What the MX refuses before it accepts. The defaults of the running
# container first: two subject rules in the generated map, the envelope
# checks in their lists, and the two checks on the client's own DNS
# absent, because they refuse a legitimate sender whose provider keeps
# no reverse record.
HEADER_MAP="$(docker exec "${NAME}" cat /etc/postfix/header_checks 2>&1)"
if [[ "${HEADER_MAP}" == *'/^Subject:[[:space:]]*=\?/   DUNNO'* \
   && "${HEADER_MAP}" == *"REJECT Subject does not seem to be reasonable"* \
   && "${HEADER_MAP}" == *"REJECT Empty subject not accepted"* ]]; then
    _pass "subject_rules_default"
else
    _fail "subject_rules_default" "${HEADER_MAP}"
fi

SENDER="$(docker exec "${NAME}" postconf -h smtpd_sender_restrictions 2>&1)"
if [[ "${SENDER}" == *"reject_unknown_sender_domain"* ]]; then
    _pass "sender_domain_default"
else
    _fail "sender_domain_default" "${SENDER}"
fi
if [[ "${RECIPIENT}" == *"reject_multi_recipient_bounce"* ]]; then
    _pass "multi_recipient_bounce_default"
else
    _fail "multi_recipient_bounce_default" "${RECIPIENT}"
fi
CLIENT="$(docker exec "${NAME}" postconf -h smtpd_client_restrictions 2>&1)"
if [[ "${CLIENT}" != *"reject_unknown_reverse_client_hostname"* \
   && "${CLIENT}" != *"reject_unknown_client_hostname"* ]]; then
    _pass "client_dns_checks_off_by_default"
else
    _fail "client_dns_checks_off_by_default" "${CLIENT}"
fi
for setting in smtpd_reject_unlisted_recipient smtpd_delay_reject disable_vrfy_command; do
    VALUE="$(docker exec "${NAME}" postconf -h "${setting}" 2>&1)"
    if [[ "${VALUE}" == "yes" ]]; then
        _pass "default_${setting}"
    else
        _fail "default_${setting}" "${setting} = '${VALUE}'"
    fi
done
if docker exec "${NAME}" test -e /etc/postfix/sender_access 2> /dev/null; then
    _fail "no_sender_access_by_default" "the map exists although nothing asked for it"
else
    _pass "no_sender_access_by_default"
fi

# Every switch flipped, in a container of its own: each check lands in
# front of the blocklist lookups of its list, and the empty-sender map
# carries the operator's own text.
SWITCHED="${NAME}-switched"
docker run -d --name "${SWITCHED}" --pull=never \
    -e HOSTNAME=mail.example.com -e DOMAIN=example.com \
    -e DB_HOST=db.example.com -e DB_NAME=postfix -e DB_USER=postfix -e DB_PASSWORD=contract-secret \
    -e REJECT_UNKNOWN_SENDER_DOMAIN=no \
    -e REJECT_MULTI_RECIPIENT_BOUNCE=no \
    -e REJECT_UNLISTED_RECIPIENT=no \
    -e SMTPD_DELAY_REJECT=no \
    -e DISABLE_VRFY_COMMAND=no \
    -e REJECT_UNKNOWN_REVERSE_CLIENT_HOSTNAME=yes \
    -e REJECT_UNKNOWN_CLIENT_HOSTNAME=yes \
    -e REJECT_EMPTY_SENDER=yes \
    -e REJECT_EMPTY_SENDER_TEXT="Please name a sender" \
    -e REJECT_SHOUTING_SUBJECT=no \
    -e REJECT_EMPTY_SUBJECT=no \
    "${IMAGE}" > /dev/null 2>&1
SWITCHED_LOG=""
for _ in $(seq 1 60); do
    SWITCHED_LOG="$(docker logs "${SWITCHED}" 2>&1)"
    [[ "${SWITCHED_LOG}" == *"**** plausibility:"* ]] && break
    sleep 1
done

SENDER="$(docker exec "${SWITCHED}" postconf -h smtpd_sender_restrictions 2>&1)"
if [[ "${SENDER}" != *"reject_unknown_sender_domain"* \
   && "${SENDER}" == *"check_sender_access regexp:/etc/postfix/sender_access"* ]]; then
    _pass "switched_sender_restrictions"
else
    _fail "switched_sender_restrictions" "${SENDER} / log: ${SWITCHED_LOG}"
fi
SENDER_MAP="$(docker exec "${SWITCHED}" cat /etc/postfix/sender_access 2>&1)"
if [[ "${SENDER_MAP}" == *"REJECT Please name a sender"* ]]; then
    _pass "switched_empty_sender_text"
else
    _fail "switched_empty_sender_text" "${SENDER_MAP}"
fi
CLIENT="$(docker exec "${SWITCHED}" postconf -h smtpd_client_restrictions 2>&1)"
if [[ "${CLIENT}" == *"reject_unknown_reverse_client_hostname"* \
   && "${CLIENT}" == *"reject_unknown_client_hostname"* ]]; then
    _pass "switched_client_dns_checks"
else
    _fail "switched_client_dns_checks" "${CLIENT}"
fi
RECIPIENT_SWITCHED="$(docker exec "${SWITCHED}" postconf -h smtpd_recipient_restrictions 2>&1)"
if [[ "${RECIPIENT_SWITCHED}" != *"reject_multi_recipient_bounce"* ]]; then
    _pass "switched_bounce_check_off"
else
    _fail "switched_bounce_check_off" "${RECIPIENT_SWITCHED}"
fi
for setting in smtpd_reject_unlisted_recipient smtpd_delay_reject disable_vrfy_command; do
    VALUE="$(docker exec "${SWITCHED}" postconf -h "${setting}" 2>&1)"
    if [[ "${VALUE}" == "no" ]]; then
        _pass "switched_${setting}"
    else
        _fail "switched_${setting}" "${setting} = '${VALUE}'"
    fi
done
HEADER_OFF="$(docker exec "${SWITCHED}" postconf -h header_checks 2>&1)"
if [[ -z "${HEADER_OFF}" ]]; then
    _pass "switched_subject_rules_off"
else
    _fail "switched_subject_rules_off" "header_checks = '${HEADER_OFF}'"
fi

TLS_LEVEL="$(docker exec "${NAME}" postconf -h smtpd_tls_security_level 2> /dev/null)"
if [[ "${TLS_LEVEL}" == "may" ]]; then
    _pass "tls_security_level_may"
else
    _fail "tls_security_level_may" "smtpd_tls_security_level = '${TLS_LEVEL}'"
fi

WARNINGS="$(docker exec "${NAME}" postconf -n 2>&1 > /dev/null)"
if [[ -z "${WARNINGS}" ]]; then
    _pass "started_no_postconf_warnings"
else
    _fail "started_no_postconf_warnings" "postconf warns: ${WARNINGS}"
fi

# A newline in an SMTP text would add a rule of its own to the map, so
# the start stops instead of rendering it.
INJECT="$(docker run --rm --pull=never --network none \
    -e DOMAIN=example.com -e DB_HOST=db.example.com -e DB_NAME=postfix \
    -e DB_USER=postfix -e DB_PASSWORD=contract-secret \
    -e REJECT_EMPTY_SENDER_TEXT=$'no sender\n/^.*$/ REJECT everything' \
    "${IMAGE}" 2>&1)"
if [[ "${INJECT}" == *"invalid REJECT_EMPTY_SENDER_TEXT"* ]]; then
    _pass "reject_text_with_newline"
else
    _fail "reject_text_with_newline" "the start did not refuse it: ${INJECT}"
fi

echo ""
echo "==> Image contract results: ${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -gt 0 ]]; then
    echo "==> Failed contracts: ${FAILED_NAMES[*]}"
    exit 1
fi
