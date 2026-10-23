# Changelog

- 2026-10-23 **2.0.2**
    - The version line 2 is built and published again as `mwaeckerlin/postfix:2`, on every push to this branch and every week with the run on master, so it gets the security fixes of its base image; the published image now contains the removal of a stale `master.pid`, which lets a replaced container come up
    - A test checks the image: the configuration is valid, and a started container takes the certificate, the database settings and the milters with OpenDMARC after OpenDKIM, removes a stale `master.pid` and answers on port 25 with STARTTLS
