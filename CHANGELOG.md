# Changelog

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
