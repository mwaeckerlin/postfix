#!/usr/bin/env bash
# Config validation: init must refuse malformed environment values.
#
# Every DB_* value is rendered into the /etc/postfix/sql/*.cf map files
# (plain key = value lines) and every other knob is fed to `postconf -e`.
# A value containing a newline would smuggle arbitrary extra directives
# into those files (config injection); a non-numeric limit would render
# an invalid main.cf. init therefore whitelist-validates every value up
# front and exits with a clear `invalid <VAR>` error before anything
# else runs.
#
# The image is shell-free, so the checks run from outside: the
# `--healthcheck` entrypoint path performs the same validation first,
# fails fast (no daemon is running) and never touches the network —
# `--network none` pins that. `--pull=never` keeps docker from testing
# a stale registry image instead of the local build.
#
# Usage: tests/config-validation.sh IMAGE

set -uo pipefail

IMAGE="${1:-mwaeckerlin/postfix}"

PASS=0
FAIL=0
declare -a FAILED_NAMES

_pass() { PASS=$((PASS + 1)); echo "  PASS  $1"; }
_fail() { FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1"); echo "  FAIL  $1: $2"; }

_image_exists() {
    if docker image inspect "${IMAGE}" > /dev/null 2>&1; then
        return 0
    fi
    _fail "image_exists" "image not built — run 'npm run build' first"
    return 1
}

# A malformed value must abort with a message naming the variable.
_reject() {
    local name="$1" var="$2" value="$3"
    local out rc
    out=$(timeout 30 docker run --rm --pull=never --network none \
              -e "${var}=${value}" "${IMAGE}" --healthcheck 2>&1)
    rc=$?
    if [[ ${rc} -ne 0 && "${out}" == *"invalid ${var}"* ]]; then
        _pass "reject_${name}"
    else
        _fail "reject_${name}" "value not rejected (rc=${rc}): ${out}"
    fi
}

# A well-formed value must pass validation (the probe itself fails —
# no daemon is running — but no validation error may appear).
_accept() {
    local name="$1"
    shift
    local out
    out=$(timeout 30 docker run --rm --pull=never --network none \
              "$@" "${IMAGE}" --healthcheck 2>&1)
    if [[ "${out}" == *"invalid "* ]]; then
        _fail "accept_${name}" "valid value rejected: ${out}"
    else
        _pass "accept_${name}"
    fi
}

echo "==> Config validation: malformed environment must be refused"

_image_exists || { echo ""; echo "==> Config validation results: 0 passed, 1 failed"; exit 1; }

_reject db_password_injection DB_PASSWORD $'secret\nhosts = evil.example'
_reject db_user_injection     DB_USER     $'postfixadmin\npassword = stolen'
_reject db_host_bad           DB_HOST     "evil host"
_reject db_name_injection     DB_NAME     $'postfixadmin\nquery = select 1'
_reject mynetworks_injection  MYNETWORKS  $'10.0.0.0/8\nsmtpd_tls_auth_only = no'
_reject hostname_bad          HOSTNAME    "mail.example.com bad"
_reject domain_bad            DOMAIN      $'example.com\nmynetworks = 0.0.0.0/0'
_reject hostroot_traversal    HOSTROOT    "../../../etc"
_reject rspamd_bad            RSPAMD      "rspamd:11332 extra"
_reject relayhost_bad         RELAYHOST   $'relay.example.com\nsmtpd_sasl_auth_enable = yes'
_reject size_not_numeric      MESSAGE_SIZE_LIMIT    "100G"
_reject hard_error_bad        SMTP_HARD_ERROR_LIMIT "many"
_reject loglevel_out_of_range POSTFIX_TLS_LOGLEVEL  "9"
_reject cleartext_auth_bad    POSTFIX_ALLOW_CLEARTEXT_AUTH "maybe"
_reject tls_required_bad      SMTPD_TLS_REQUIRED    "sometimes"

_accept defaults
_accept explicit_values \
    -e DB_USER=postfixadmin \
    -e DB_PASSWORD='s3cret-Pa55!' \
    -e DB_HOST=postfixadmin-db \
    -e DB_NAME=postfixadmin \
    -e MYNETWORKS='127.0.0.0/8, [::1]/128' \
    -e HOSTNAME=mail.example.com \
    -e HOSTROOT=example.com \
    -e DOMAIN=example.com \
    -e RSPAMD=rspamd:11332 \
    -e RELAYHOST=relay.example.com:587 \
    -e MESSAGE_SIZE_LIMIT=107374182400 \
    -e SMTP_HARD_ERROR_LIMIT=20 \
    -e POSTFIX_TLS_LOGLEVEL=2 \
    -e POSTFIX_ALLOW_CLEARTEXT_AUTH=no \
    -e SMTPD_TLS_REQUIRED=yes

echo ""
echo "==> Config validation results: ${PASS} passed, ${FAIL} failed"
if [[ ${FAIL} -gt 0 ]]; then
    echo "==> Failed checks: ${FAILED_NAMES[*]}"
    exit 1
fi
