# Postfix Docker Image

Docker Image for Full Featured Postfix Server

## What the server refuses before it accepts

Everything this image rejects at SMTP time is an environment variable, `yes` or `no`, so nothing a stack accepts has to be dropped later.

| Variable | Default | Description |
|----------|---------|-------------|
| `REJECT_SHOUTING_SUBJECT` | `yes` | Refuse a subject without a single lowercase letter. A MIME-encoded subject is exempt: postfix matches the raw header and never decodes RFC 2047, so no rule about letter case applies to base64. |
| `REJECT_SHOUTING_SUBJECT_TEXT` | `Subject does not seem to be reasonable, looks like SPAM` | The SMTP error text of the check above. |
| `REJECT_EMPTY_SUBJECT` | `yes` | Refuse a Subject header that carries nothing. |
| `REJECT_EMPTY_SUBJECT_TEXT` | `Empty subject not accepted, please specify a subject` | The SMTP error text of the check above. |
| `REJECT_UNKNOWN_SENDER_DOMAIN` | `yes` | Refuse a sender whose domain has neither an A nor an MX record: nobody could answer his mail. While the resolver itself is unreachable postfix answers `450`, so a DNS outage defers the mail instead of rejecting it. |
| `REJECT_MULTI_RECIPIENT_BOUNCE` | `yes` | Refuse a bounce (`<>` as envelope sender) that names more than one recipient. A real bounce carries exactly one. |
| `REJECT_UNLISTED_RECIPIENT` | `yes` | Refuse a recipient the domain does not know at SMTP time instead of accepting the mail and bouncing it afterwards. |
| `SMTPD_DELAY_REJECT` | `yes` | Report a rejection after `RCPT TO` rather than at the command that caused it, so the log carries the sender and the recipient of every refused mail. |
| `DISABLE_VRFY_COMMAND` | `yes` | Answer `VRFY` with an error: the command tells a stranger which addresses exist. |
| `REJECT_UNKNOWN_REVERSE_CLIENT_HOSTNAME` | `no` | Refuse a client whose IP address has no reverse record. Off by default: a provider without a `PTR` record still sends legitimate mail, and the big providers accept him too. |
| `REJECT_UNKNOWN_CLIENT_HOSTNAME` | `no` | The same, and also demanding that the reverse name resolves back to the address. Off by default for the same reason, and it refuses more. |
| `REJECT_EMPTY_SENDER` | `no` | Refuse an empty envelope sender. Off by default: RFC 5321 gives a bounce an empty sender, so a stack that refuses it never learns that its own mail bounced. |
| `REJECT_EMPTY_SENDER_TEXT` | `Empty envelope sender not accepted` | The SMTP error text of the check above. |

Every envelope check stands in front of the blocklist lookups of its restriction list: a check on the envelope costs nothing, a blocklist lookup costs a DNS query, and postfix stops at the first check that rejects.
