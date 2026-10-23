# Changelog

- 2026-10-23 **1.11.1**
    - The version line 1 is built and published again as `mwaeckerlin/postfix:1`, on every push to this branch and every week with the run on master, so it gets the security fixes of its base image; the published image now contains the removal of a stale `master.pid`, which lets a replaced container come up
    - A test checks the image: the configuration is valid, and a started container takes the certificate, the database settings and the milters, removes a stale `master.pid` and answers on port 25 with STARTTLS
