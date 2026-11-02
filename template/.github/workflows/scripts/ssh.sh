#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ---------------------------------------------------------------------------
# Prepare SSH private key, known_hosts and client configuration
# ---------------------------------------------------------------------------

prepare_ssh() {
  local secrets="$1"
  local dir="$2"

  local host
  local user
  local key
  local known
  local path

  require_commands ssh ssh-keygen mkdir chmod

  [[ -n "$secrets" && -r "$secrets" ]] ||
    die "Deployment secrets file is unavailable"

  [[ -n "$dir" ]] ||
    die "SSH configuration directory is required"

  # Read deployment configuration from OpenBao.
  host="$(json_secret "$secrets" DEPLOY_HOST)"
  user="$(json_secret "$secrets" DEPLOY_USER)"
  key="$(json_secret "$secrets" DEPLOY_SSH_KEY)"
  known="$(json_secret "$secrets" DEPLOY_KNOWN_HOSTS)"
  path="$(json_secret "$secrets" DEPLOY_PATH)"

  # Validate values used in the SSH configuration.
  [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] ||
    die "Invalid DEPLOY_HOST"

  [[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] ||
    die "Invalid DEPLOY_USER"

  [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    die "Invalid DEPLOY_PATH"

  [[ "$path" != *"/../"* && "$path" != */.. && "$path" != *"/./"* ]] ||
    die "DEPLOY_PATH contains an invalid path component"

  [[ "$path" != "/" ]] ||
    die "DEPLOY_PATH cannot be the filesystem root"

  [[ -n "$key" ]] ||
    die "DEPLOY_SSH_KEY is empty"

  [[ -n "$known" ]] ||
    die "DEPLOY_KNOWN_HOSTS is empty"

  # Use an absolute directory path.
  mkdir -p "$dir"
  dir="$(cd -- "$dir" && pwd)"
  chmod 700 "$dir"

  # Store credentials in protected files.
  printf '%s\n' "$key" > "${dir}/id"
  printf '%s\n' "$known" > "${dir}/known_hosts"

  chmod 600 "${dir}/id" "${dir}/known_hosts"

  # Validate the private key. CI keys must not require a passphrase.
  ssh-keygen -y -P "" -f "${dir}/id" >/dev/null ||
    die "Invalid SSH private key or key requires a passphrase"

  # Verify that known_hosts contains an entry for the deployment host.
  ssh-keygen -F "$host" -f "${dir}/known_hosts" >/dev/null ||
    die "No known_hosts entry found for DEPLOY_HOST '${host}'"

  # Generate an isolated SSH configuration.
  cat > "${dir}/config" <<CFG
Host target
  HostName ${host}
  User ${user}
  IdentityFile ${dir}/id
  IdentitiesOnly yes
  BatchMode yes
  PreferredAuthentications publickey
  PasswordAuthentication no
  KbdInteractiveAuthentication no
  StrictHostKeyChecking yes
  UserKnownHostsFile ${dir}/known_hosts
  ServerAliveInterval 15
  ServerAliveCountMax 3
CFG

  chmod 600 "${dir}/config"

  log "SSH configuration prepared for host '${host}' and user '${user}'"
}