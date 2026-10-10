#!/usr/bin/env bash
# Deploy the built Jekyll site (_site/) to a UW CSE home web directory.
#
# Usage: .github/scripts/deploy-cse.sh [--check | --dry-run] [--help]
#
#   --check    Run network/SSH diagnostics only; do not transfer files.
#   --dry-run  Run diagnostics, then show what rsync would change.
#
# Environment:
#   CSE_USERNAME          (required) CSE login name.
#   CSE_HOST              SSH host. Default: recycle.cs.washington.edu
#   CSE_SSH_PORT          SSH port. Default: 22
#   CSE_REMOTE_PATH       Remote directory. Default: /cse/web/homes/$CSE_USERNAME/
#   CSE_SITE_DIR          Local build output. Default: _site
#   CSE_SSH_PRIVATE_KEY   Private key contents (CI). Written to a temp dir, removed on exit.
#   CSE_SSH_KEY_FILE      Path to a private key file (local use). Ignored if
#                         CSE_SSH_PRIVATE_KEY is set. If neither is set, ssh uses
#                         your normal agent/identities.
#   CSE_SSH_KNOWN_HOSTS   Pinned known_hosts line(s) for CSE_HOST. Recommended.
#                         If unset, ~/.ssh/known_hosts is consulted, then
#                         ssh-keyscan is used as a last resort (trust on first use).
#   CSE_CONNECT_TIMEOUT   Seconds for TCP/SSH connect. Default: 15

set -euo pipefail

mode=deploy
case "${1:-}" in
  "") ;;
  --check) mode=check ;;
  --dry-run) mode=dry-run ;;
  -h|--help) sed -n '2,/^$/s/^# \{0,1\}//p' "$0"; exit 0 ;;
  *) echo "Unknown argument: $1 (see --help)" >&2; exit 2 ;;
esac

: "${CSE_USERNAME:?CSE_USERNAME is required}"
host="${CSE_HOST:-recycle.cs.washington.edu}"
port="${CSE_SSH_PORT:-22}"
remote_path="${CSE_REMOTE_PATH:-/cse/web/homes/${CSE_USERNAME}/}"
site_dir="${CSE_SITE_DIR:-_site}"
timeout="${CSE_CONNECT_TIMEOUT:-15}"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; [[ -n "${GITHUB_ACTIONS:-}" ]] && printf '::warning::%s\n' "$*"; return 0; }
die()  { printf 'ERROR: %s\n' "$*" >&2; [[ -n "${GITHUB_ACTIONS:-}" ]] && printf '::error::%s\n' "$*"; exit 1; }

for cmd in ssh ssh-keygen ssh-keyscan rsync; do
  command -v "$cmd" >/dev/null || die "'$cmd' is not installed on this machine."
done

ssh_dir="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/cse-ssh.XXXXXX")"
trap 'rm -rf "$ssh_dir"' EXIT
chmod 700 "$ssh_dir"
known_hosts="$ssh_dir/known_hosts"
umask 077

# --- Identity -----------------------------------------------------------------
key_file=""
if [[ -n "${CSE_SSH_PRIVATE_KEY:-}" ]]; then
  key_file="$ssh_dir/id_deploy"
  # Normalise CRLF line endings, which commonly sneak into pasted secrets.
  printf '%s\n' "$CSE_SSH_PRIVATE_KEY" | tr -d '\r' > "$key_file"
  chmod 600 "$key_file"
elif [[ -n "${CSE_SSH_KEY_FILE:-}" ]]; then
  [[ -r "$CSE_SSH_KEY_FILE" ]] || die "CSE_SSH_KEY_FILE '$CSE_SSH_KEY_FILE' is not readable."
  key_file="$CSE_SSH_KEY_FILE"
fi
if [[ -n "$key_file" ]]; then
  ssh-keygen -y -P '' -f "$key_file" >/dev/null 2>&1 \
    || die "SSH private key is malformed or passphrase-protected (CI keys must have no passphrase)."
fi

# --- Diagnostics: DNS ---------------------------------------------------------
log "Resolving $host"
addrs=""
if command -v getent >/dev/null; then
  addrs="$(getent ahosts "$host" | awk '{print $1}' | sort -u || true)"
elif command -v dig >/dev/null; then
  addrs="$(dig +short "$host" A "$host" AAAA || true)"
elif command -v host >/dev/null; then
  addrs="$(host "$host" | awk '/has (IPv6 )?address/ {print $NF}' || true)"
fi
[[ -n "$addrs" ]] || die "DNS resolution failed for $host."
printf '%s\n' "$addrs" | sed 's/^/    /'

# --- Diagnostics: TCP ---------------------------------------------------------
log "Checking TCP connectivity to $host:$port"
tcp_ok=false
if command -v nc >/dev/null; then
  nc -z -w "$timeout" "$host" "$port" >/dev/null 2>&1 && tcp_ok=true
else
  # Bash /dev/tcp fallback with a manual timeout (no coreutils `timeout` on macOS).
  ( exec 3<>"/dev/tcp/$host/$port" ) 2>/dev/null & pid=$!
  ( sleep "$timeout"; kill "$pid" 2>/dev/null ) & watcher=$!
  wait "$pid" 2>/dev/null && tcp_ok=true
  kill "$watcher" 2>/dev/null || true
fi
$tcp_ok || die "Cannot open TCP connection to $host:$port. This machine has no route to the CSE SSH service (firewall or off-campus network)."
echo "    TCP connect OK"

# --- Host key -----------------------------------------------------------------
log "Preparing known_hosts for $host"
host_entry="$host"
[[ "$port" == 22 ]] || host_entry="[$host]:$port"
if [[ -n "${CSE_SSH_KNOWN_HOSTS:-}" ]]; then
  printf '%s\n' "$CSE_SSH_KNOWN_HOSTS" | tr -d '\r' > "$known_hosts"
  echo "    Using pinned CSE_SSH_KNOWN_HOSTS"
elif [[ -f "$HOME/.ssh/known_hosts" ]] && ssh-keygen -F "$host_entry" -f "$HOME/.ssh/known_hosts" >/dev/null 2>&1; then
  ssh-keygen -F "$host_entry" -f "$HOME/.ssh/known_hosts" | grep -v '^#' > "$known_hosts"
  echo "    Using existing entry from ~/.ssh/known_hosts"
else
  warn "CSE_SSH_KNOWN_HOSTS is not set; falling back to ssh-keyscan (trust on first use). Pin the host key to avoid this."
  if ! ssh-keyscan -T "$timeout" -p "$port" "$host" > "$known_hosts" 2> "$ssh_dir/keyscan.err" || [[ ! -s "$known_hosts" ]]; then
    sed 's/^/    /' "$ssh_dir/keyscan.err" >&2
    die "ssh-keyscan returned no host keys for $host: this network is blocked or briefly throttled."
  fi
fi
[[ -s "$known_hosts" ]] || die "known_hosts for $host is empty."
echo "    Host key fingerprints:"
ssh-keygen -l -f "$known_hosts" | sed 's/^/      /'

# --- SSH options --------------------------------------------------------------
ssh_opts=(
  -p "$port"
  -o BatchMode=yes
  -o ConnectTimeout="$timeout"
  -o StrictHostKeyChecking=yes
  -o UserKnownHostsFile="$known_hosts"
  -o GlobalKnownHostsFile=/dev/null
  -o ServerAliveInterval=15
  -o ServerAliveCountMax=4
)
[[ -n "$key_file" ]] && ssh_opts+=(-i "$key_file" -o IdentitiesOnly=yes)

# --- Diagnostics: SSH ---------------------------------------------------------
log "Testing SSH login as $CSE_USERNAME@$host (BatchMode=yes, ConnectTimeout=$timeout)"
# shellcheck disable=SC2029
if ! ssh "${ssh_opts[@]}" "$CSE_USERNAME@$host" "test -d '$remote_path' && test -w '$remote_path'" 2> "$ssh_dir/ssh.err"; then
  sed 's/^/    /' "$ssh_dir/ssh.err" >&2
  if grep -q 'Host key verification failed' "$ssh_dir/ssh.err"; then
    die "Host key for $host does not match the pinned key. Verify the fingerprint before updating CSE_SSH_KNOWN_HOSTS."
  elif grep -qE 'kex_exchange_identification|Connection reset|Connection closed by' "$ssh_dir/ssh.err"; then
    die "CSE closed the connection before authentication: this network is blocked or briefly throttled. Retry in a minute, or run from the UW network. See .github/DEPLOY-CSE.md."
  elif grep -q 'Permission denied' "$ssh_dir/ssh.err"; then
    die "SSH authentication failed for $CSE_USERNAME. Check that the public key is in ~/.ssh/authorized_keys on CSE."
  elif [[ ! -s "$ssh_dir/ssh.err" ]]; then
    die "SSH login worked, but remote path '$remote_path' is missing or not writable."
  fi
  die "SSH connectivity test failed."
fi
echo "    SSH login OK; $remote_path is writable"

if [[ "$mode" == check ]]; then
  log "Diagnostics passed. No files were transferred (--check)."
  exit 0
fi

# --- Deploy -------------------------------------------------------------------
[[ -f "$site_dir/index.html" ]] || die "'$site_dir/index.html' not found. Run 'bundle exec jekyll build' first; refusing to rsync --delete an empty/incomplete site."
[[ "$remote_path" == /?* && ! "$remote_path" =~ ^/+$ ]] \
  || die "Refusing to rsync --delete into remote path '$remote_path'."

rsync_opts=(-avz --delete)
[[ "$mode" == dry-run ]] && rsync_opts+=(--dry-run)

ssh_cmd="ssh"
for opt in "${ssh_opts[@]}"; do ssh_cmd+=" $(printf '%q' "$opt")"; done

log "rsync ${rsync_opts[*]} $site_dir/ -> $CSE_USERNAME@$host:$remote_path"
rsync "${rsync_opts[@]}" -e "$ssh_cmd" "$site_dir/" "$CSE_USERNAME@$host:$remote_path"

if [[ "$mode" == dry-run ]]; then
  log "Dry run complete. No files were changed."
else
  log "Deployment complete."
fi
