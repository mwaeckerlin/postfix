# Postfix Docker Image

Docker Image for Full Featured Postfix Server

Best used as the MTA of https://github.com/mwaeckerlin/mailservice — see that README for the full stack (dovecot, rspamd, clamav, redis, postfixadmin, webmail) and all configuration knobs.

## Headless image

The image is headless: a small compiled `init` binary configures postfix from the environment and execs the postfix `master` daemon in container mode — no shell, no busybox, no perl, no package manager in the shipped image. `init --healthcheck` TCP-probes the SMTP listener on 127.0.0.1:25 and can be wired as a Docker healthcheck:

```yaml
healthcheck:
  test: ["CMD", "/usr/bin/init", "--healthcheck"]
```

Trade-off: the container starts as root — the postfix master needs it to bind port 25 and manage the mail queue — and every postfix service then drops privileges to the unprivileged `postfix` user per master.cf. All master.cf services run with `chroot=n`: the classic postfix chroot jail needs a populated jail directory maintained by the shell-based `postfix-script`/`post-install` tooling that a headless image cannot ship. The containment lost is small — the container image itself contains no shell, no busybox and no perl to pivot to, which is the stronger boundary.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DOMAIN` | — | Mail domain (`mydomain`). |
| `HOSTNAME` | `$DOMAIN` | `myhostname`. |
| `HOSTROOT` | `$HOSTNAME` | Let's Encrypt cert directory name under `/etc/letsencrypt/live/`. |
| `DB_HOST` / `DB_NAME` / `DB_USER` / `DB_PASSWORD` | — | PostfixAdmin database for the virtual domain/mailbox/alias maps. |
| `DB_PORT` | — (MySQL default `3306`) | Port of the PostfixAdmin database, added to every host in `DB_HOST` that names no port of its own. |
| `DOVECOT_HOST` | `dovecot` | Host of the dovecot service: mail is delivered there via LMTP, SMTP logins are checked there via SASL. |
| `DOVECOT_LMTP_PORT` | `24` | LMTP port of dovecot (`virtual_transport` / `mailbox_transport = lmtp:inet:<host>:<port>`). |
| `DOVECOT_SASL_PORT` | `12345` | SASL port of dovecot (`smtpd_sasl_path = inet:<host>:<port>`). |
| `RSPAMD` | — | Rspamd milter, `host` or `host:port` (default port 11332): DKIM sign/verify, DMARC, SPF, greylist, Bayes, antivirus. |
| `MILTER_DEFAULT_ACTION` | `accept` | What postfix does with a mail while the rspamd milter is unreachable: `accept`, `tempfail`, `reject` or `quarantine`. See «milter fail-open» below. |
| `MYNETWORKS` | `127.0.0.1/32` | Networks allowed to relay without authenticating. Every other sender needs a mailbox and SASL. The relay images this one builds on default to the private ranges, which on a docker swarm means every container of every stack, so the mail server narrows it to the loopback address; widen it only for a host that genuinely cannot authenticate. |
| `RELAYHOST` | — | Relay all outbound mail through this host, `host` or `host:port`. |
| `DISABLE_DNSBL` | — | Set non-empty to drop the RBL lookups (test / offline stacks). Wins over the two lists below. |
| `DNSBL_SERVERS` | `ix.dnsbl.manitu.net=127.0.0.[2..11] sbl.spamhaus.org=127.0.0.[2..11] xbl.spamhaus.org=127.0.0.[2..11]` | Space-separated `reject_rbl_client` zones, looked up with the client's IP address. Each zone names the return codes that mean a listing; see the note below. |
| `RHSBL_SERVERS` | `dbl.spamhaus.org=127.0.1.[2..99]` | Space-separated zones of `reject_rhsbl_sender`, `reject_rhsbl_client` and `reject_rhsbl_helo`, looked up with the sender domain, the client host name and the HELO name. |
| `MESSAGE_SIZE_LIMIT` | `107374182400` (100 GiB) | Max accepted message size in bytes, `0` = unlimited; `mailbox_size_limit` is pinned to the same value. High on purpose — a legitimate mail must never bounce on an artificial default. |
| `SMTP_HARD_ERROR_LIMIT` | `20` (postfix standard) | Hard SMTP protocol errors per session before disconnect. |
| `POSTFIX_TLS_LOGLEVEL` | `0` | TLS handshake logging (smtpd/smtp/lmtp). `2` = handshake debug — a diagnostics override for test stacks, never a production default. |
| `REJECT_UNKNOWN_SENDER_DOMAIN` | `yes` | Refuse a sender whose domain has neither an A nor an MX record: nobody could answer his mail. While the resolver itself is unreachable postfix answers `450`, so a DNS outage defers the mail instead of rejecting it. |
| `REJECT_MULTI_RECIPIENT_BOUNCE` | `yes` | Refuse a bounce (`<>` as envelope sender) that names more than one recipient. A real bounce carries exactly one. |
| `REJECT_UNLISTED_RECIPIENT` | `yes` | Refuse a recipient the domain does not know at SMTP time (postfix's own default) instead of accepting the mail and bouncing it afterwards. |
| `SMTPD_DELAY_REJECT` | `yes` | Report a rejection after `RCPT TO` rather than at the command that caused it (postfix's own default), so the log carries the sender and the recipient of every refused mail. |
| `DISABLE_VRFY_COMMAND` | `yes` | Answer `VRFY` with an error: the command tells a stranger which addresses exist. |
| `REJECT_UNKNOWN_REVERSE_CLIENT_HOSTNAME` | `no` | Refuse a client whose IP address has no reverse record. Off by default: a provider without a `PTR` record still sends legitimate mail, and the big providers accept him too. |
| `REJECT_UNKNOWN_CLIENT_HOSTNAME` | `no` | The same, and also demanding that the reverse name resolves back to the address. Off by default for the same reason, and it refuses more. |
| `REJECT_EMPTY_SENDER` | `no` | Refuse an empty envelope sender. Off by default: RFC{NB}5321 gives a bounce an empty sender, so a stack that refuses it never learns that its own mail bounced. |
| `REJECT_EMPTY_SENDER_TEXT` | `Empty envelope sender not accepted` | The SMTP error text of the check above. |
| `POSTFIX_ALLOW_CLEARTEXT_AUTH` | `no` | Only relevant when no TLS certificate is present: `no` disables SASL entirely (no login without TLS), `yes` deliberately offers SASL on the unencrypted channel — only for an isolated network that cannot have certificates. |

TLS enables itself when `/etc/letsencrypt/live/$HOSTROOT/` contains `fullchain.pem` + `privkey.pem`; SASL auth is then TLS-only (`smtpd_tls_auth_only=yes`), so no password ever travels unencrypted.

**Trade-off — no certificate, no login:** without a certificate there is no STARTTLS, so offering SASL would put passwords on the wire in the clear. The image therefore disables SASL entirely in that case (same behaviour as the sibling dovecot image, where a certless stack has no usable login). A deliberately TLS-less deployment on an isolated network can opt into cleartext auth with `POSTFIX_ALLOW_CLEARTEXT_AUTH=yes` — the start-up log then carries a clear warning. Pinned by the mailservice e2e test `test_tls.py::test_smtp_auth_disabled_without_cert`.

**Trade-off — milter fail-open:** the rspamd milter is wired with `milter_default_action=accept`: if the rspamd container is down, mail is accepted without spam/virus scanning and outbound mail leaves unsigned until rspamd is back. This follows the mailservice design («reliability over filtering» — a milter outage must never bounce or drop legitimate mail); the alternative `tempfail` would defer all mail for the duration of the outage. Operators who prefer that behaviour set `MILTER_DEFAULT_ACTION=tempfail`.

**Name the return codes of every blocklist zone.** Spamhaus answers `127.255.255.252`, `.254` and `.255` when a query cannot be answered: a typing error in the zone name, a query through a public or open resolver, too many queries. Postfix counts every answer from the zone as a listing unless the rule says which codes mean one, so a server whose lookups fail rejects the mail it could not check. Measured in a production log on 2026-10-28: `554 5.7.1 … blocked using dbl.spamhaus.org; Error: open resolver`. Spamhaus warns about it in its [DNSBL usage FAQ](https://www.spamhaus.org/faqs/dnsbl-usage/): «some mail servers wrongly reject all mail on these codes». Listings live in `127.0.0.2` … `127.0.0.11` for the IP zones and in `127.0.1.0/24` for the domain zone, so a zone of your own is written `zone=127.0.0.[2..11]` with the codes its operator documents.

A query through a public resolver is answered with an error in any case, so a server that uses one gets no blocklist protection at all. Run a resolver of your own in the stack, or in the network around it.

**Environment contract:** `tests/env-config.sh` (`npm test`) starts the image with and without each of `DB_PORT`, `DOVECOT_HOST`, `DOVECOT_LMTP_PORT`, `DOVECOT_SASL_PORT`, `MILTER_DEFAULT_ACTION`, `DNSBL_SERVERS`, `RHSBL_SERVERS`, `RELAYHOST`, the two subject rules and the eight switches on the envelope, and reads the effective value with `postconf -h`, from the rendered sql maps or from the generated map file.

**Input validation:** every environment value is whitelist-validated at start-up before it is rendered into the postfix sql maps or fed to `postconf` — a malformed value (embedded newline, stray shell/config metacharacters, out-of-range number) aborts the start with a clear `invalid <VAR>` error. Pinned by `tests/config-validation.sh` (`npm test`).

## Volumes

- **`/var/mail/domains`** — the mailboxes (delivered via dovecot LMTP in the mailservice stack).
- **`/var/spool/postfix`** — the mail queue. **Must be a named volume**: postfix answers `250 Ok` as soon as a mail is safely written (fsync) into the queue — from that moment the server owns delivery and the sender never retries. A deferred mail (receiver greylisting, next hop briefly down) can sit here for hours or days; without the volume, every container recreate or image update silently destroys accepted-but-undelivered mail. Pinned by `tests/compose-contract.sh` in the mailservice stack.

SPF is verified by rspamd's SPF module. The perl-based `postfix-policyd-spf-perl` (and its `CHECK_SPF` knob) was removed with the headless image — it duplicated rspamd's verdict and was auto-disabled whenever `RSPAMD` was set.
