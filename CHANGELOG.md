# Changelog

- 2026-07-20 **submission services + transport transparency**
    - Dedicated submission listeners on 587 (STARTTLS) and 465
      (implicit TLS), separate from the port-25 MX: both enforce TLS
      and SASL authentication and drop the MX/DNSBL restrictions for
      authenticated users. Port 25 stays anonymous with opportunistic
      TLS.
    - Opportunistic TLS no longer forces a TLS 1.2 floor (only SSLv2/3
      are excluded), so a legacy peer's mail is still encrypted rather
      than pushed back to plaintext; the 1.2 floor applies where TLS is
      mandatory (submission, and the new opt-in reject).
    - New opt-in `SMTPD_TLS_REQUIRED=yes`: the MX then rejects any
      connection that will not negotiate TLS 1.2+ (deliberately
      RFC-3207-non-compliant — for internal/closed ingresses only).
    - Records the receiving hop's TLS in the `Received` header and hands
      the TLS version/cipher to the rspamd milter, which stamps the
      machine-readable `X-Transport-Security` header.
    - Config validation extended to `POSTFIX_ALLOW_CLEARTEXT_AUTH` and
      `SMTPD_TLS_REQUIRED`.

- 2026-07-18 **security hardening**
    - Without a TLS certificate the server no longer offers
      authentication at all — previously a certless deployment
      silently accepted logins over the unencrypted channel. A
      deliberately TLS-less setup (isolated network) can opt in via
      the new `POSTFIX_ALLOW_CLEARTEXT_AUTH=yes` switch; the start-up
      log then warns clearly. Pinned by an end-to-end test with valid
      credentials.
    - Every configuration value from the environment is now validated
      before use; a malformed value (for example an embedded newline
      that could smuggle extra configuration directives) refuses to
      start with a clear `invalid <VAR>` error instead of silently
      producing a broken or unsafe configuration. Covered by the new
      config-validation test suite (`npm test`).
    - Documented trade-offs: no-certificate login behaviour and the
      fail-open milter wiring (an rspamd outage never bounces mail).

- 2026-07-18 **headless image**
    - The image no longer contains a shell, busybox, perl or a package
      manager: a compiled `init` binary configures postfix from the
      environment and starts the postfix master daemon directly. All
      environment knobs (RSPAMD, TLS-by-cert-presence, DB maps,
      DISABLE_DNSBL, MYNETWORKS, RELAYHOST, limits) behave as before.
    - New `init --healthcheck` probe for Docker healthchecks.
    - Removed: `postfix-policyd-spf-perl` and the `CHECK_SPF` knob —
      SPF verification is rspamd's SPF module; the perl policy service
      duplicated the verdict and was auto-disabled whenever `RSPAMD`
      was set. Set up rspamd if you need SPF checks.
    - Debug leftovers removed from the image defaults: no more baked-in
      `debug_peer_list`, and the TLS handshake loglevel is now `0` in
      production (override with `POSTFIX_TLS_LOGLEVEL=2` for
      diagnostics, e.g. in test stacks).
    - Removed the unused `LOCAL_DOMAINS` environment variable.
    - The mail queue (`/var/spool/postfix`) is now a declared volume:
      an accepted mail (`250 Ok`) is the server's responsibility and
      the sender never retries — a deferred mail must survive container
      recreates and image updates. The mailservice compose maps it to
      a named volume, pinned by a compose-contract test.
