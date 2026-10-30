/**

postfix init: minimal, shell-free entrypoint for the mailservice
postfix container.

Follows the same three-stage / statically-linked / execv() pattern as
the sibling mwaeckerlin/rspamd and mwaeckerlin/clamav inits: parse env,
compose runtime config through postconf, exec the postfix master. The
runtime image contains no shell, no perl, no busybox.

Behaviour (port of the former start.sh, contract unchanged unless
noted):

  1. RSPAMD=host or host:port (default port 11332): merge the rspamd
     milter into smtpd_milters / non_smtpd_milters (append, keep any
     pre-existing milters, skip when already configured);
     milter_default_action from MILTER_DEFAULT_ACTION (default accept).
     Delivery and SASL go to DOVECOT_HOST on DOVECOT_LMTP_PORT /
     DOVECOT_SASL_PORT (defaults dovecot, 24, 12345).
  2. TLS is enabled when /etc/letsencrypt/live/$HOSTROOT (fallback
     $HOSTNAME, then $DOMAIN) holds fullchain.pem + privkey.pem; SASL
     is then TLS-only (smtpd_tls_auth_only=yes). WITHOUT a certificate
     SASL is disabled entirely — no password ever travels unencrypted
     (stack invariant, see the mailservice README). A deliberately
     TLS-less deployment (isolated network) can opt into cleartext
     auth with POSTFIX_ALLOW_CLEARTEXT_AUTH=yes.
  3. The six /etc/postfix/sql/*.cf maps get the DB_USER / DB_PASSWORD /
     DB_HOST / DB_NAME credentials, DB_PORT appended to every host that
     names none (idempotent rewrite: credentials first, the map's query
     last).
  4. DISABLE_DNSBL: drop the RBL lookups from the smtpd restrictions
     (test / offline stacks). Otherwise DNSBL_SERVERS / RHSBL_SERVERS
     replace the blocklist zones (unset keeps the baked-in zones).
  5. MYNETWORKS, myhostname=${HOSTNAME:-$DOMAIN}, mydomain=$DOMAIN,
     RELAYHOST → relayhost=[..].
  6. Delivery-affecting limits from env — high, configurable defaults
     (MESSAGE_SIZE_LIMIT default 100 GiB, 0 = unlimited;
     mailbox_size_limit pinned to the same value;
     SMTP_HARD_ERROR_LIMIT default 20, the postfix standard).
  7. POSTFIX_TLS_LOGLEVEL (default 0 — production default; the e2e
     stack sets 2 for diagnosable handshake logs).
  8. postsuper queue sanity, then exec master in init mode (-i) as
     PID 1. maillog_file=/dev/stdout keeps logs on stdout.
  9. Every env value is whitelist-validated before it is rendered into
     the sql map files or fed to postconf — a malformed value (a
     newline above all: config injection) aborts the start with a
     clear `invalid <VAR>` error. Pinned by tests/config-validation.sh.

Removed vs. v3.0 (headless): the perl-based postfix-policyd-spf-perl
and its CHECK_SPF knob. SPF verification is rspamd's SPF module — the
policy service duplicated the work and was auto-disabled whenever
RSPAMD was set.

Supports --healthcheck: TCP-probes the SMTP listener at 127.0.0.1:25.

*/

#include <arpa/inet.h>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <exception>
#include <filesystem>
#include <fstream>
#include <iostream>
#include <netinet/in.h>
#include <set>
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;

namespace {

constexpr const char *HEADER_CHECKS = "/etc/postfix/header_checks";
constexpr const char *SENDER_ACCESS = "/etc/postfix/sender_access";

constexpr const char *POSTCONF  = "/usr/sbin/postconf";
constexpr const char *POSTSUPER = "/usr/sbin/postsuper";
constexpr const char *MASTER    = "/usr/libexec/postfix/master";

constexpr const char *SQL_CONFIGS[] = {
    "/etc/postfix/sql/mysql_virtual_alias_domain_catchall_maps.cf",
    "/etc/postfix/sql/mysql_virtual_alias_domain_mailbox_maps.cf",
    "/etc/postfix/sql/mysql_virtual_alias_domain_maps.cf",
    "/etc/postfix/sql/mysql_virtual_alias_maps.cf",
    "/etc/postfix/sql/mysql_virtual_domains_maps.cf",
    "/etc/postfix/sql/mysql_virtual_mailbox_maps.cf",
};

std::string
env_or(const char *name, const std::string &fallback = {}) {
  const char *v = std::getenv(name);
  return (v && *v) ? std::string(v) : fallback;
}

// Every env value is rendered into the sql map files (plain key=value
// lines) or fed to `postconf -e`, so an unvalidated value — a newline
// above all — would inject arbitrary extra directives (config
// injection). Operator input is input: whitelist-validate each value
// class and refuse to start on anything malformed (pinned by
// tests/config-validation.sh).
[[noreturn]] void
die_invalid(const char *var, const std::string &value) {
  std::cerr << "**** ERROR: invalid " << var << " \"" << value
            << "\" — refusing to start" << std::endl;
  std::exit(1);
}

// Empty stays allowed: every knob is optional — validation constrains
// only what IS set.
void
check_chars(const char *var, const std::string &v, const std::string &extra) {
  for (char c : v)
    if (!std::isalnum(static_cast<unsigned char>(c)) &&
        extra.find(c) == std::string::npos)
      die_invalid(var, v);
}

// A secret must not be echoed back into the container log on error.
void
check_no_crlf_secret(const char *var, const std::string &v) {
  if (v.find_first_of("\r\n") != std::string::npos) {
    std::cerr << "**** ERROR: invalid " << var
              << " (value withheld) — refusing to start" << std::endl;
    std::exit(1);
  }
}

long
check_num(const char *var, const std::string &v, long min, long max) {
  if (v.empty() || v.size() > 15 ||
      v.find_first_not_of("0123456789") != std::string::npos)
    die_invalid(var, v);
  long n = std::atol(v.c_str());
  if (n < min || n > max) die_invalid(var, v);
  return n;
}

// Capture ONLY stdout — stderr stays on the container log. postconf
// prints deprecation warnings on stderr; mixing them into a captured
// `postconf -h` value (e.g. smtpd_milters) would feed multi-line
// garbage back into `postconf -e` — a fatal.
int
run_capture(const std::vector<const char *> &argv, std::string &out) {
  int pipefd[2];
  if (pipe(pipefd) < 0) throw std::runtime_error("pipe");
  pid_t pid = fork();
  if (pid < 0) throw std::runtime_error("fork");
  if (pid == 0) {
    close(pipefd[0]);
    dup2(pipefd[1], 1);
    close(pipefd[1]);
    std::vector<char *> a;
    for (auto *s : argv) a.push_back(const_cast<char *>(s));
    a.push_back(nullptr);
    execv(a[0], a.data());
    _exit(127);
  }
  close(pipefd[1]);
  char buf[4096];
  ssize_t n;
  while ((n = read(pipefd[0], buf, sizeof buf)) > 0) out.append(buf, n);
  close(pipefd[0]);
  int status = 0;
  waitpid(pid, &status, 0);
  return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

void
postconf_set(const std::string &name, const std::string &value) {
  std::string out;
  const std::string assignment = name + "=" + value;
  if (run_capture({POSTCONF, "-e", assignment.c_str()}, out) != 0)
    throw std::runtime_error("postconf -e " + assignment + " failed: " + out);
}

std::string
postconf_get(const std::string &name) {
  std::string out;
  if (run_capture({POSTCONF, "-h", name.c_str()}, out) != 0)
    throw std::runtime_error("postconf -h " + name + " failed: " + out);
  while (!out.empty() && (out.back() == '\n' || out.back() == '\r'))
    out.pop_back();
  return out;
}

std::string
with_default_port(std::string hostport, const std::string &port) {
  if (hostport.find(':') == std::string::npos) hostport += ":" + port;
  return hostport;
}

std::string
trim(const std::string &s) {
  const auto b = s.find_first_not_of(" \t");
  if (b == std::string::npos) return {};
  const auto e = s.find_last_not_of(" \t");
  return s.substr(b, e - b + 1);
}

std::vector<std::string>
split_ws(const std::string &s) {
  std::vector<std::string> out;
  std::istringstream in(s);
  std::string tok;
  while (in >> tok) out.push_back(tok);
  return out;
}

// Append the milter to smtpd_milters / non_smtpd_milters, keeping any
// pre-existing entries; skip the merge when already configured.
void
add_milter(const std::string &addr, const std::string &default_action) {
  const std::string inet = "inet:" + addr;
  const std::string cur = postconf_get("smtpd_milters");
  if (cur.empty()) {
    postconf_set("smtpd_milters",     inet);
    postconf_set("non_smtpd_milters", inet);
  } else if (cur.find(inet) == std::string::npos) {
    postconf_set("smtpd_milters", cur + ", " + inet);
    const std::string cur_non = postconf_get("non_smtpd_milters");
    postconf_set("non_smtpd_milters",
                 cur_non.empty() ? inet : cur_non + ", " + inet);
  }
  postconf_set("milter_default_action", default_action);
  postconf_set("milter_protocol",       "6");
}

void
configure_dovecot(const std::string &host, const std::string &lmtp_port,
                  const std::string &sasl_port) {
  const std::string lmtp = "lmtp:inet:" + host + ":" + lmtp_port;
  postconf_set("virtual_transport", lmtp);
  postconf_set("mailbox_transport", lmtp);
  postconf_set("smtpd_sasl_path",   "inet:" + host + ":" + sasl_port);
  std::cerr << "**** dovecot: " << lmtp << ", SASL inet:" << host << ":"
            << sasl_port << std::endl;
}

// Each blocklist check (reject_rbl_client, reject_rhsbl_<kind>) keeps
// its place in every restriction list, with the zones from the env.
void
set_blocklists(const std::string &rbl, const std::string &rhsbl) {
  if (rbl.empty() && rhsbl.empty()) return;
  for (const char *param : {"smtpd_client_restrictions",
                            "smtpd_helo_restrictions",
                            "smtpd_sender_restrictions",
                            "smtpd_recipient_restrictions",
                            "smtpd_relay_restrictions"}) {
    std::vector<std::string> items;
    std::set<std::string> done;
    std::istringstream in(postconf_get(param));
    std::string item;
    while (std::getline(in, item, ',')) {
      item = trim(item);
      if (item.empty()) continue;
      const std::string kind = item.substr(0, item.find_first_of(" \t"));
      const bool is_rbl   = kind == "reject_rbl_client";
      const bool is_rhsbl = kind.rfind("reject_rhsbl_", 0) == 0;
      const std::string &zones = is_rbl ? rbl : rhsbl;
      if ((!is_rbl && !is_rhsbl) || zones.empty()) {
        items.push_back(item);
        continue;
      }
      if (!done.insert(kind).second) continue;
      for (const auto &zone : split_ws(zones)) items.push_back(kind + " " + zone);
    }
    std::string joined;
    for (const auto &i : items) joined += (joined.empty() ? "" : ", ") + i;
    postconf_set(param, joined);
  }
  std::cerr << "**** DNSBL zones: " << (rbl.empty() ? "(built-in)" : rbl)
            << "; RHSBL zones: " << (rhsbl.empty() ? "(built-in)" : rhsbl)
            << std::endl;
}

// The brackets suppress the MX lookup; a port stays outside them.
std::string
bracket_relayhost(const std::string &relayhost) {
  const auto colon = relayhost.find(':');
  if (colon == std::string::npos) return "[" + relayhost + "]";
  return "[" + relayhost.substr(0, colon) + "]" + relayhost.substr(colon);
}

// DB_PORT goes to every host of DB_HOST (comma separated) without one.
std::string
with_db_port(const std::string &hosts, const std::string &port) {
  if (port.empty()) return hosts;
  std::string out;
  std::istringstream in(hosts);
  std::string host;
  while (std::getline(in, host, ',')) {
    host = trim(host);
    if (host.empty()) continue;
    if (host.find(':') == std::string::npos) host += ":" + port;
    out += (out.empty() ? "" : ", ") + host;
  }
  return out;
}

// Rewrite one sql map: DB credentials first, the map's `query` line
// last — same result as the previous start.sh sed pipeline, idempotent
// across container restarts.
void
write_sql_config(const fs::path &path,
                 const std::string &user, const std::string &password,
                 const std::string &host, const std::string &name) {
  std::ifstream in(path);
  if (!in) throw std::runtime_error("cannot read " + path.string());
  std::string query;
  for (std::string line; std::getline(in, line); )
    if (line.rfind("query", 0) == 0) query = line;
  in.close();
  if (query.empty())
    throw std::runtime_error("no query line in " + path.string());

  std::ofstream out(path, std::ios::trunc);
  if (!out) throw std::runtime_error("cannot write " + path.string());
  out << "user     = " << user     << "\n"
      << "password = " << password << "\n"
      << "hosts    = " << host     << "\n"
      << "dbname   = " << name     << "\n"
      << query << "\n";
}

void
configure_tls(const std::string &certdomain) {
  const std::string live = "/etc/letsencrypt/live/" + certdomain;
  const bool require_tls = env_or("SMTPD_TLS_REQUIRED", "no") == "yes";
  if (fs::exists(live + "/fullchain.pem") &&
      fs::exists(live + "/privkey.pem")) {
    postconf_set("smtpd_tls_cert_file",       live + "/fullchain.pem");
    postconf_set("smtpd_tls_key_file",        live + "/privkey.pem");
    postconf_set("smtpd_use_tls",             "yes");
    // Opportunistic by default (may): a legacy peer without TLS 1.2
    // falls back to plaintext and the mail still arrives — RFC 7435,
    // delivery before filtering. SMTPD_TLS_REQUIRED=yes flips this to
    // `encrypt`: every inbound connection MUST negotiate TLS (and, via
    // smtpd_tls_mandatory_protocols=>=TLSv1.2, at least 1.2) or the
    // mail is rejected. That is deliberately RFC-3207-non-compliant for
    // a public MX (a peer without modern TLS can no longer deliver) —
    // fit for internal / closed / B2B ingresses. See README.
    postconf_set("smtpd_tls_security_level",  require_tls ? "encrypt" : "may");
    postconf_set("smtpd_tls_auth_only",       "yes");
    postconf_set("smtp_tls_note_starttls_offer", "yes");
    std::cerr << "**** Status: TLS configured for " << certdomain
              << " on " << live
              << (require_tls ? " (REQUIRED: non-TLS/<1.2 rejected)"
                              : " (opportunistic)")
              << std::endl;
  } else if (require_tls) {
    // Cannot enforce TLS without a certificate — fail fast rather than
    // silently accept cleartext while claiming to require encryption.
    throw std::runtime_error(
        "SMTPD_TLS_REQUIRED=yes but no certificate at " + live +
        " — cannot enforce TLS without a cert");
  } else if (env_or("POSTFIX_ALLOW_CLEARTEXT_AUTH", "no") == "yes") {
    // Deliberate operator opt-in for a TLS-less deployment (isolated
    // network): SASL stays enabled and passwords travel in the clear.
    postconf_set("smtpd_tls_auth_only", "no");
    std::cerr << "#### WARNING! Status: TLS NOT configured for "
              << certdomain << " on " << live
              << " — POSTFIX_ALLOW_CLEARTEXT_AUTH=yes: passwords travel"
              << " UNENCRYPTED" << std::endl;
  } else {
    // Stack invariant: passwords never travel unencrypted. No cert
    // means no STARTTLS, so offering SASL here would put credentials
    // on the wire in the clear — disable SASL instead (same behaviour
    // as dovecot: a stack without a certificate has no usable login).
    postconf_set("smtpd_sasl_auth_enable", "no");
    std::cerr << "#### WARNING! Status: TLS NOT configured for "
              << certdomain << " on " << live
              << " — SASL auth DISABLED (no login without TLS; set"
              << " POSTFIX_ALLOW_CLEARTEXT_AUTH=yes to deliberately"
              << " allow cleartext auth on an isolated network)"
              << std::endl;
  }
}

// Two subject rules, evaluated by cleanup(8) during DATA, before the
// message is accepted. That is the only place in this stack where a
// rule about the header refuses delivery without this server sending
// anything: the sending host keeps the message and its own provider
// informs the real sender. A rule that runs later, at delivery time,
// can only answer the address in MAIL FROM, which unwanted mail
// forges.
//
// The first line exempts a MIME-encoded subject (RFC 2047). Postfix
// matches the raw header and never decodes it (header_checks(5),
// section BUGS: «when message headers are encoded (RFC 2047) then the
// rules need to be specified for the encoded form»), so a subject in
// Cyrillic, Arabic or Chinese, and a German one with umlauts, arrives
// as `=?UTF-8?B?…?=`. A rule about capital letters says nothing about
// base64, so those subjects are let through before the rules below
// ever see them.
//
// The shouting rule demands at least one capital Latin letter and no
// lowercase one. A subject in a script without capital letters carries
// no [A-Z] and is not matched.
void
write_header_checks() {
  const std::string shouting = env_or("REJECT_SHOUTING_SUBJECT", "yes");
  const std::string empty    = env_or("REJECT_EMPTY_SUBJECT",    "yes");
  const std::string shouting_text =
      env_or("REJECT_SHOUTING_SUBJECT_TEXT",
             "Subject does not seem to be reasonable, looks like SPAM");
  const std::string empty_text =
      env_or("REJECT_EMPTY_SUBJECT_TEXT",
             "Empty subject not accepted, please specify a subject");

  if (shouting != "yes" && shouting != "no")
    die_invalid("REJECT_SHOUTING_SUBJECT", shouting);
  if (empty != "yes" && empty != "no")
    die_invalid("REJECT_EMPTY_SUBJECT", empty);
  // The text is rendered into a line of the map file; a newline there
  // would add a rule of its own.
  check_chars("REJECT_SHOUTING_SUBJECT_TEXT", shouting_text, " .,;:!?()'\"/-_@");
  check_chars("REJECT_EMPTY_SUBJECT_TEXT",    empty_text,    " .,;:!?()'\"/-_@");

  if (shouting == "no" && empty == "no") {
    postconf_set("header_checks", "");
    std::cerr << "**** subject header checks disabled" << std::endl;
    return;
  }

  std::ofstream out(HEADER_CHECKS, std::ios::trunc);
  if (!out) throw std::runtime_error("cannot write " + std::string(HEADER_CHECKS));
  out << "# Written by the postfix init from REJECT_SHOUTING_SUBJECT,\n"
         "# REJECT_EMPTY_SUBJECT and their _TEXT variables. Edits are\n"
         "# overwritten on every container start.\n"
         "\n"
         "# A MIME-encoded subject carries base64 or quoted-printable,\n"
         "# so no rule about letter case applies to it.\n"
         "/^Subject:[[:space:]]*=\\?/   DUNNO\n";
  if (shouting == "yes")
    out << "\n# At least one capital Latin letter and no lowercase one.\n"
        << "/^Subject:[^a-z]*[A-Z][^a-z]*$/   REJECT " << shouting_text << "\n";
  if (empty == "yes")
    out << "\n# A Subject header that is present and carries nothing.\n"
        << "/^Subject:[[:space:]]*$/   REJECT " << empty_text << "\n";
  out.close();

  postconf_set("header_checks", std::string("regexp:") + HEADER_CHECKS);
  std::cerr << "**** subject header checks: shouting=" << shouting
            << ", empty=" << empty << std::endl;
}

// yes / no, with a clear abort on anything else.
bool
flag(const char *var, const char *fallback) {
  const std::string value = env_or(var, fallback);
  if (value != "yes" && value != "no") die_invalid(var, value);
  return value == "yes";
}

// Add a check to a restriction list, once, in front of the first
// blocklist lookup of that list: a check on the envelope itself costs
// nothing, a blocklist lookup costs a DNS query, and postfix stops at
// the first check that rejects.
void
insert_restriction(const char *param, const std::string &check) {
  const std::string current = postconf_get(param);
  if (current.find(check) != std::string::npos) return;
  if (current.empty()) {
    postconf_set(param, check);
    return;
  }
  std::vector<std::string> items;
  bool placed = false;
  std::istringstream in(current);
  std::string item;
  while (std::getline(in, item, ',')) {
    item = trim(item);
    if (item.empty()) continue;
    const std::string kind = item.substr(0, item.find_first_of(" \t"));
    if (!placed && (kind == "reject_rbl_client" ||
                    kind.rfind("reject_rhsbl_", 0) == 0)) {
      items.push_back(check);
      placed = true;
    }
    items.push_back(item);
  }
  if (!placed) items.push_back(check);
  std::string joined;
  for (const auto &i : items) joined += (joined.empty() ? "" : ", ") + i;
  postconf_set(param, joined);
}

// Plausibility of the envelope, each one a switch. The two that reject
// on the client's own DNS are off by default: a sender whose provider
// keeps no reverse record is a legitimate sender, and the big providers
// accept him too. So is the empty envelope sender, which RFC 5321 gives
// every bounce.
void
configure_plausibility() {
  const bool sender_domain = flag("REJECT_UNKNOWN_SENDER_DOMAIN",      "yes");
  const bool bounce        = flag("REJECT_MULTI_RECIPIENT_BOUNCE",     "yes");
  const bool unlisted      = flag("REJECT_UNLISTED_RECIPIENT",         "yes");
  const bool delay         = flag("SMTPD_DELAY_REJECT",                "yes");
  const bool vrfy          = flag("DISABLE_VRFY_COMMAND",              "yes");
  const bool reverse       = flag("REJECT_UNKNOWN_REVERSE_CLIENT_HOSTNAME", "no");
  const bool client        = flag("REJECT_UNKNOWN_CLIENT_HOSTNAME",    "no");
  const bool empty_sender  = flag("REJECT_EMPTY_SENDER",               "no");
  const std::string empty_sender_text =
      env_or("REJECT_EMPTY_SENDER_TEXT",
             "Empty envelope sender not accepted");
  check_chars("REJECT_EMPTY_SENDER_TEXT", empty_sender_text,
              " .,;:!?()'\"/-_@");

  // A sender domain without an A or MX record cannot receive the
  // answer to its own mail. postfix answers 450 while DNS itself is
  // unreachable, so a resolver outage defers instead of rejecting.
  if (sender_domain)
    insert_restriction("smtpd_sender_restrictions",
                       "reject_unknown_sender_domain");
  // A bounce carries exactly one recipient; several name a forged one.
  if (bounce)
    insert_restriction("smtpd_recipient_restrictions",
                       "reject_multi_recipient_bounce");
  if (reverse)
    insert_restriction("smtpd_client_restrictions",
                       "reject_unknown_reverse_client_hostname");
  if (client)
    insert_restriction("smtpd_client_restrictions",
                       "reject_unknown_client_hostname");

  // The envelope sender of a bounce is empty by RFC 5321, so a stack
  // that refuses it never learns that its own mail bounced.
  if (empty_sender) {
    std::ofstream out(SENDER_ACCESS, std::ios::trunc);
    if (!out)
      throw std::runtime_error("cannot write " + std::string(SENDER_ACCESS));
    out << "# Written by the postfix init from REJECT_EMPTY_SENDER and\n"
           "# REJECT_EMPTY_SENDER_TEXT. Edits are overwritten on every\n"
           "# container start.\n"
           "\n"
           "# smtpd_null_access_lookup_key: postfix looks the empty\n"
           "# envelope sender up as <>.\n"
        << "/^<>$/   REJECT " << empty_sender_text << "\n";
    out.close();
    insert_restriction("smtpd_sender_restrictions",
                       std::string("check_sender_access regexp:")
                           + SENDER_ACCESS);
  }

  postconf_set("smtpd_reject_unlisted_recipient", unlisted ? "yes" : "no");
  postconf_set("smtpd_delay_reject",              delay    ? "yes" : "no");
  postconf_set("disable_vrfy_command",            vrfy     ? "yes" : "no");

  const auto word = [](bool on) { return on ? "yes" : "no"; };
  std::cerr << "**** plausibility: sender_domain=" << word(sender_domain)
            << ", multi_recipient_bounce=" << word(bounce)
            << ", unlisted_recipient=" << word(unlisted)
            << ", delay_reject=" << word(delay)
            << ", vrfy_disabled=" << word(vrfy)
            << ", unknown_reverse_client=" << word(reverse)
            << ", unknown_client=" << word(client)
            << ", empty_sender_rejected=" << word(empty_sender) << std::endl;
}

void
configure_limits() {
  const std::string size = env_or("MESSAGE_SIZE_LIMIT",    "107374182400");
  const std::string herr = env_or("SMTP_HARD_ERROR_LIMIT", "20");
  postconf_set("message_size_limit",     size);
  postconf_set("mailbox_size_limit",     size);
  postconf_set("smtpd_hard_error_limit", herr);
  std::cerr << "**** message_size_limit=" << size
            << ", smtpd_hard_error_limit=" << herr << std::endl;
}

[[noreturn]] void
exec_master() {
  std::string out;
  if (run_capture({POSTSUPER}, out) != 0)
    throw std::runtime_error("postsuper queue sanity failed: " + out);
  if (!out.empty()) std::cerr << out;

  if (getpid() == 1) {
    const char *argv[] = {"master", "-i", nullptr};
    execv(MASTER, const_cast<char *const *>(argv));
  } else {
    const char *argv[] = {"master", "-d", "-s", nullptr};
    execv(MASTER, const_cast<char *const *>(argv));
  }
  std::perror(MASTER);
  std::exit(1);
}

// --------------------------------------------------- healthcheck ----------

int
tcp_probe(const std::string &host, int port) {
  int s = socket(AF_INET, SOCK_STREAM, 0);
  if (s < 0) return 1;
  sockaddr_in addr{};
  addr.sin_family = AF_INET;
  addr.sin_port = htons(port);
  inet_pton(AF_INET, host.c_str(), &addr.sin_addr);
  int rc = connect(s, reinterpret_cast<sockaddr *>(&addr), sizeof addr);
  close(s);
  return rc == 0 ? 0 : 1;
}

} // namespace

int main(int argc, char *argv[]) try {
  const std::string rspamd      = env_or("RSPAMD");
  const std::string domain      = env_or("DOMAIN");
  const std::string hostname    = env_or("HOSTNAME", domain);
  const std::string hostroot    = env_or("HOSTROOT", hostname);
  const std::string db_user     = env_or("DB_USER");
  const std::string db_password = env_or("DB_PASSWORD");
  const std::string db_host     = env_or("DB_HOST");
  const std::string db_name     = env_or("DB_NAME");
  const std::string db_port     = env_or("DB_PORT");
  const std::string mynetworks  = env_or("MYNETWORKS");
  const std::string relayhost   = env_or("RELAYHOST");
  const std::string cleartext   = env_or("POSTFIX_ALLOW_CLEARTEXT_AUTH", "no");
  const std::string dovecot     = env_or("DOVECOT_HOST",      "dovecot");
  const std::string lmtp_port   = env_or("DOVECOT_LMTP_PORT", "24");
  const std::string sasl_port   = env_or("DOVECOT_SASL_PORT", "12345");
  const std::string milter_action = env_or("MILTER_DEFAULT_ACTION", "accept");
  const std::string dnsbl       = env_or("DNSBL_SERVERS");
  const std::string rhsbl       = env_or("RHSBL_SERVERS");

  // Validate every env value before it is rendered anywhere — also on
  // the --healthcheck path, so a misconfigured container reports
  // unhealthy instead of probing a listener that never came up.
  check_chars("RSPAMD",     rspamd,     ".-_:");
  check_chars("DOMAIN",     domain,     ".-");
  check_chars("HOSTNAME",   hostname,   ".-");
  check_chars("HOSTROOT",   hostroot,   ".-");   // no '/': path segment only
  check_chars("DB_USER",    db_user,    "._-");
  check_no_crlf_secret("DB_PASSWORD", db_password);
  check_chars("DB_HOST",    db_host,    ".-_:,");
  check_chars("DB_NAME",    db_name,    "._-");
  check_chars("MYNETWORKS", mynetworks, " ./:,[]!-");
  check_chars("RELAYHOST",  relayhost,  ".-_:");
  if (!db_port.empty()) check_num("DB_PORT", db_port, 1, 65535);
  check_chars("DOVECOT_HOST", dovecot, ".-_");
  check_num("DOVECOT_LMTP_PORT", lmtp_port, 1, 65535);
  check_num("DOVECOT_SASL_PORT", sasl_port, 1, 65535);
  if (milter_action != "accept" && milter_action != "reject" &&
      milter_action != "tempfail" && milter_action != "quarantine")
    die_invalid("MILTER_DEFAULT_ACTION", milter_action);
  // A zone may carry the return codes that mean a listing, as
  // `zone=127.0.0.[2..11]`, so an error answer of the list is not read
  // as one. See the comment at the built-in zones in the Dockerfile.
  check_chars("DNSBL_SERVERS", dnsbl, ".-=[] ");
  check_chars("RHSBL_SERVERS", rhsbl, ".-=[] ");
  check_num("MESSAGE_SIZE_LIMIT",
            env_or("MESSAGE_SIZE_LIMIT", "107374182400"), 0, 999999999999999L);
  check_num("SMTP_HARD_ERROR_LIMIT",
            env_or("SMTP_HARD_ERROR_LIMIT", "20"), 1, 1000000);
  check_num("POSTFIX_TLS_LOGLEVEL",
            env_or("POSTFIX_TLS_LOGLEVEL", "0"), 0, 4);
  if (cleartext != "yes" && cleartext != "no")
    die_invalid("POSTFIX_ALLOW_CLEARTEXT_AUTH", cleartext);
  const std::string require_tls = env_or("SMTPD_TLS_REQUIRED", "no");
  if (require_tls != "yes" && require_tls != "no")
    die_invalid("SMTPD_TLS_REQUIRED", require_tls);
  // A malformed plausibility switch stops the start here, before a
  // single postconf call, like every other knob.
  for (const char *var : {"REJECT_UNKNOWN_SENDER_DOMAIN",
                          "REJECT_MULTI_RECIPIENT_BOUNCE",
                          "REJECT_UNLISTED_RECIPIENT",
                          "SMTPD_DELAY_REJECT",
                          "DISABLE_VRFY_COMMAND",
                          "REJECT_UNKNOWN_REVERSE_CLIENT_HOSTNAME",
                          "REJECT_UNKNOWN_CLIENT_HOSTNAME",
                          "REJECT_EMPTY_SENDER"})
    flag(var, "no");
  check_chars("REJECT_EMPTY_SENDER_TEXT",
              env_or("REJECT_EMPTY_SENDER_TEXT", ""), " .,;:!?()'\"/-_@");

  if (argc > 1 && std::string(argv[1]) == "--healthcheck")
    return tcp_probe("127.0.0.1", 25);

  // Rspamd milter — one single upstream that covers DKIM signing +
  // DKIM verify + DMARC + SPF + greylist + Bayes + ClamAV.
  if (!rspamd.empty()) {
    const std::string addr = with_default_port(rspamd, "11332");
    add_milter(addr, milter_action);
    std::cerr << "**** Rspamd milter configured: " << addr
              << ", milter_default_action=" << milter_action << std::endl;
  }

  configure_dovecot(dovecot, lmtp_port, sasl_port);

  configure_tls(hostroot);

  for (const char *cfg : SQL_CONFIGS)
    write_sql_config(cfg, db_user, db_password,
                     with_db_port(db_host, db_port), db_name);

  if (env_or("DISABLE_DNSBL").empty()) {
    set_blocklists(dnsbl, rhsbl);
  } else {
    postconf_set("smtpd_client_restrictions",
        "permit_sasl_authenticated");
    postconf_set("smtpd_helo_restrictions",
        "permit_sasl_authenticated, permit_mynetworks, "
        "reject_non_fqdn_hostname, reject_unauth_pipelining");
    postconf_set("smtpd_recipient_restrictions",
        "permit_sasl_authenticated, permit_mynetworks, "
        "reject_unknown_recipient_domain, reject_non_fqdn_recipient, "
        "reject_unauth_pipelining");
    postconf_set("smtpd_relay_restrictions",
        "permit_sasl_authenticated, reject_unknown_recipient_domain, "
        "reject_non_fqdn_recipient, reject_unauth_pipelining, "
        "reject_unauth_destination");
    std::cerr << "**** DNSBL/RBL checks disabled" << std::endl;
  }

  if (!mynetworks.empty()) {
    postconf_set("mynetworks", mynetworks);
    std::cerr << "**** mynetworks restricted to " << mynetworks << std::endl;
  }

  postconf_set("myhostname", hostname);
  postconf_set("mydomain",   domain);

  configure_limits();
  configure_plausibility();
  write_header_checks();

  // TLS handshake logging: production default 0; diagnostics override
  // for test stacks (never bake a debug loglevel into the image).
  const std::string tls_loglevel = env_or("POSTFIX_TLS_LOGLEVEL", "0");
  postconf_set("smtpd_tls_loglevel", tls_loglevel);
  postconf_set("smtp_tls_loglevel",  tls_loglevel);
  postconf_set("lmtp_tls_loglevel",  tls_loglevel);

  if (!relayhost.empty()) {
    postconf_set("relayhost", bracket_relayhost(relayhost));
    std::cerr << "**** All outbound mail relayed through "
              << relayhost << std::endl;
  }

  std::cerr << "**** Starting postfix master for " << hostname << std::endl;
  exec_master();
} catch (const std::exception &e) {
  std::cerr << "EXCEPTION: " << e.what() << std::endl;
  return 1;
} catch (...) {
  std::cerr << "UNKNOWN ERROR" << std::endl;
  return 1;
}
