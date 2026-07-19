# Postfix Docker Image

Docker Image for Full Featured Postfix Server

Best used as the MTA of https://github.com/mwaeckerlin/mailservice —
see that README for the full stack (dovecot, rspamd, clamav, redis,
postfixadmin, webmail) and all configuration knobs.

## Headless image

The image is headless: a small compiled `init` binary configures
postfix from the environment and execs the postfix `master` daemon in
container mode — no shell, no busybox, no perl, no package manager in
the shipped image. `init --healthcheck` TCP-probes the SMTP listener
on 127.0.0.1:25 and can be wired as a Docker healthcheck:

```yaml
healthcheck:
  test: ["CMD", "/usr/bin/init", "--healthcheck"]
```

Trade-off: the container starts as root — the postfix master needs it
to bind port 25 and manage the mail queue — and every postfix service
then drops privileges to the unprivileged `postfix` user per
master.cf. All master.cf services run with `chroot=n`: the classic
postfix chroot jail needs a populated jail directory maintained by the
shell-based `postfix-script`/`post-install` tooling that a headless
image cannot ship. The containment lost is small — the container image
itself contains no shell, no busybox and no perl to pivot to, which is
the stronger boundary.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DOMAIN` | — | Mail domain (`mydomain`). |
| `HOSTNAME` | `$DOMAIN` | `myhostname`. |
| `HOSTROOT` | `$HOSTNAME` | Let's Encrypt cert directory name under `/etc/letsencrypt/live/`. |
| `DB_HOST` / `DB_NAME` / `DB_USER` / `DB_PASSWORD` | — | PostfixAdmin database for the virtual domain/mailbox/alias maps. |
| `RSPAMD` | — | Rspamd milter, `host` or `host:port` (default port 11332): DKIM sign/verify, DMARC, SPF, greylist, Bayes, antivirus. |
| `MYNETWORKS` | postfix default | Networks allowed to relay. |
| `RELAYHOST` | — | Relay all outbound mail through this host. |
| `DISABLE_DNSBL` | — | Set non-empty to drop the RBL lookups (test / offline stacks). |
| `MESSAGE_SIZE_LIMIT` | `107374182400` (100 GiB) | Max accepted message size in bytes, `0` = unlimited; `mailbox_size_limit` is pinned to the same value. High on purpose — a legitimate mail must never bounce on an artificial default. |
| `SMTP_HARD_ERROR_LIMIT` | `20` (postfix standard) | Hard SMTP protocol errors per session before disconnect. |
| `POSTFIX_TLS_LOGLEVEL` | `0` | TLS handshake logging (smtpd/smtp/lmtp). `2` = handshake debug — a diagnostics override for test stacks, never a production default. |
| `POSTFIX_ALLOW_CLEARTEXT_AUTH` | `no` | Only relevant when no TLS certificate is present: `no` disables SASL entirely (no login without TLS), `yes` deliberately offers SASL on the unencrypted channel — only for an isolated network that cannot have certificates. |

TLS enables itself when `/etc/letsencrypt/live/$HOSTROOT/` contains
`fullchain.pem` + `privkey.pem`; SASL auth is then TLS-only
(`smtpd_tls_auth_only=yes`), so no password ever travels unencrypted.

**Trade-off — no certificate, no login:** without a certificate there
is no STARTTLS, so offering SASL would put passwords on the wire in
the clear. The image therefore disables SASL entirely in that case
(same behaviour as the sibling dovecot image, where a certless stack
has no usable login). A deliberately TLS-less deployment on an
isolated network can opt into cleartext auth with
`POSTFIX_ALLOW_CLEARTEXT_AUTH=yes` — the start-up log then carries a
clear warning. Pinned by the mailservice e2e test
`test_tls.py::test_smtp_auth_disabled_without_cert`.

**Trade-off — milter fail-open:** the rspamd milter is wired with
`milter_default_action=accept`: if the rspamd container is down, mail
is accepted without spam/virus scanning and outbound mail leaves
unsigned until rspamd is back. This follows the mailservice design
(«reliability over filtering» — a milter outage must never bounce or
drop legitimate mail); the alternative `tempfail` would defer all mail
for the duration of the outage. Operators who prefer that behaviour
can override `milter_default_action` via `postconf` in a derived
image.

**Input validation:** every environment value is whitelist-validated
at start-up before it is rendered into the postfix sql maps or fed to
`postconf` — a malformed value (embedded newline, stray shell/config
metacharacters, out-of-range number) aborts the start with a clear
`invalid <VAR>` error. Pinned by `tests/config-validation.sh`
(`npm test`).

## Volumes

- **`/var/mail/domains`** — the mailboxes (delivered via dovecot LMTP
  in the mailservice stack).
- **`/var/spool/postfix`** — the mail queue. **Must be a named
  volume**: postfix answers `250 Ok` as soon as a mail is safely
  written (fsync) into the queue — from that moment the server owns
  delivery and the sender never retries. A deferred mail (receiver
  greylisting, next hop briefly down) can sit here for hours or days;
  without the volume, every container recreate or image update
  silently destroys accepted-but-undelivered mail. Pinned by
  `tests/compose-contract.sh` in the mailservice stack.

SPF is verified by rspamd's SPF module. The perl-based
`postfix-policyd-spf-perl` (and its `CHECK_SPF` knob) was removed with
the headless image — it duplicated rspamd's verdict and was
auto-disabled whenever `RSPAMD` was set.
