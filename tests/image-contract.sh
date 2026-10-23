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
    docker rm -f "${NAME}" > /dev/null 2>&1
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

echo ""
echo "==> Image contract results: ${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -gt 0 ]]; then
    echo "==> Failed contracts: ${FAILED_NAMES[*]}"
    exit 1
fi
