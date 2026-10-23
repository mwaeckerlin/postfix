# Changelog

- 2026-10-23 **1.11.2**
    - TLS on port 25 is set by `smtpd_tls_security_level` alone, `none` without a certificate and `may` with one, as before; the deprecated `smtpd_use_tls` beside it is gone, and the deprecated `smtpd_tls_eecdh_grade` is no longer inherited from `mwaeckerlin/mailforward`, so postconf no longer warns about the configuration
    - The image builds without a warning of the docker build checks
    - A test checks the TLS level of a started container and that postconf prints no warning, in the image and in the started container

- 2026-10-23 **1.11.1**
    - The version line 1 is built and published again as `mwaeckerlin/postfix:1`, on every push to this branch and every week with the run on master, so it gets the security fixes of its base image; the published image now contains the removal of a stale `master.pid`, which lets a replaced container come up
    - A test checks the image: the configuration is valid, and a started container takes the certificate, the database settings and the milters, removes a stale `master.pid` and answers on port 25 with STARTTLS
