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
     pre-existing milters, skip when already configured).
  2. TLS is enabled when /etc/letsencrypt/live/$HOSTROOT (fallback
     $HOSTNAME, then $DOMAIN) holds fullchain.pem + privkey.pem; SASL
     is then TLS-only (smtpd_tls_auth_only=yes).
  3. The six /etc/postfix/sql/*.cf maps get the DB_USER / DB_PASSWORD /
     DB_HOST / DB_NAME credentials (idempotent rewrite: credentials
     first, the map's query last).
  4. DISABLE_DNSBL: drop the RBL lookups from the smtpd restrictions
     (test / offline stacks).
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
#include <sstream>
#include <stdexcept>
#include <string>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

namespace fs = std::filesystem;

namespace {

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

// Append the milter to smtpd_milters / non_smtpd_milters, keeping any
// pre-existing entries; skip when already configured.
void
add_milter(const std::string &addr) {
  const std::string inet = "inet:" + addr;
  const std::string cur = postconf_get("smtpd_milters");
  if (cur.find(inet) != std::string::npos) return;  // already configured
  if (cur.empty()) {
    postconf_set("smtpd_milters",     inet);
    postconf_set("non_smtpd_milters", inet);
  } else {
    postconf_set("smtpd_milters", cur + ", " + inet);
    const std::string cur_non = postconf_get("non_smtpd_milters");
    postconf_set("non_smtpd_milters",
                 cur_non.empty() ? inet : cur_non + ", " + inet);
  }
  postconf_set("milter_default_action", "accept");
  postconf_set("milter_protocol",       "6");
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
  if (fs::exists(live + "/fullchain.pem") &&
      fs::exists(live + "/privkey.pem")) {
    postconf_set("smtpd_tls_cert_file",       live + "/fullchain.pem");
    postconf_set("smtpd_tls_key_file",        live + "/privkey.pem");
    postconf_set("smtpd_use_tls",             "yes");
    postconf_set("smtpd_tls_security_level",  "may");
    postconf_set("smtpd_tls_auth_only",       "yes");
    postconf_set("smtp_tls_note_starttls_offer", "yes");
    std::cerr << "**** Status: TLS configured for " << certdomain
              << " on " << live << std::endl;
  } else {
    postconf_set("smtpd_tls_auth_only", "no");
    std::cerr << "#### WARNING! Status: TLS NOT configured for "
              << certdomain << " on " << live << std::endl;
  }
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
  if (argc > 1 && std::string(argv[1]) == "--healthcheck")
    return tcp_probe("127.0.0.1", 25);

  // Rspamd milter — one single upstream that covers DKIM signing +
  // DKIM verify + DMARC + SPF + greylist + Bayes + ClamAV.
  const std::string rspamd = env_or("RSPAMD");
  if (!rspamd.empty()) {
    const std::string addr = with_default_port(rspamd, "11332");
    add_milter(addr);
    std::cerr << "**** Rspamd milter configured: " << addr << std::endl;
  }

  const std::string domain   = env_or("DOMAIN");
  const std::string hostname = env_or("HOSTNAME", domain);
  configure_tls(env_or("HOSTROOT", hostname));

  for (const char *cfg : SQL_CONFIGS)
    write_sql_config(cfg, env_or("DB_USER"), env_or("DB_PASSWORD"),
                     env_or("DB_HOST"), env_or("DB_NAME"));

  if (!env_or("DISABLE_DNSBL").empty()) {
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

  const std::string mynetworks = env_or("MYNETWORKS");
  if (!mynetworks.empty()) {
    postconf_set("mynetworks", mynetworks);
    std::cerr << "**** mynetworks restricted to " << mynetworks << std::endl;
  }

  postconf_set("myhostname", hostname);
  postconf_set("mydomain",   domain);

  configure_limits();

  // TLS handshake logging: production default 0; diagnostics override
  // for test stacks (never bake a debug loglevel into the image).
  const std::string tls_loglevel = env_or("POSTFIX_TLS_LOGLEVEL", "0");
  postconf_set("smtpd_tls_loglevel", tls_loglevel);
  postconf_set("smtp_tls_loglevel",  tls_loglevel);
  postconf_set("lmtp_tls_loglevel",  tls_loglevel);

  const std::string relayhost = env_or("RELAYHOST");
  if (!relayhost.empty()) {
    postconf_set("relayhost", "[" + relayhost + "]");
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
