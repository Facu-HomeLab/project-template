#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

prepare_ssh() {
  local secret_file="$1" dir host user key known path
  dir="${RUNNER_TEMP:-/tmp}/deploy-ssh-${GITHUB_RUN_ID:-manual}"
  mkdir -p "$dir"; chmod 700 "$dir"
  host="$(json_secret "$secret_file" DEPLOY_HOST)"
  user="$(json_secret "$secret_file" DEPLOY_USER)"
  key="$(json_secret "$secret_file" DEPLOY_SSH_KEY)"
  known="$(json_secret "$secret_file" DEPLOY_KNOWN_HOSTS)"
  path="$(json_secret "$secret_file" DEPLOY_PATH)"
  [[ "$host" =~ ^[A-Za-z0-9.-]+$ ]] || die "Invalid DEPLOY_HOST"
  [[ "$user" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid DEPLOY_USER"
  [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ && "$path" != *"/../"* && "$path" != */.. ]] || die "Invalid DEPLOY_PATH"
  printf '%s\n' "$key" > "$dir/id_deploy"; chmod 600 "$dir/id_deploy"
  printf '%s\n' "$known" > "$dir/known_hosts"; chmod 600 "$dir/known_hosts"
  ssh-keygen -y -f "$dir/id_deploy" >/dev/null || die "DEPLOY_SSH_KEY is invalid"
  cat > "$dir/config" <<EOF
Host deploy-target
  HostName $host
  User $user
  IdentityFile $dir/id_deploy
  IdentitiesOnly yes
  BatchMode yes
  StrictHostKeyChecking yes
  UserKnownHostsFile $dir/known_hosts
  ServerAliveInterval 15
  ServerAliveCountMax 3
EOF
  chmod 600 "$dir/config"
  printf 'ssh_dir=%s\n' "$dir" >> "$GITHUB_OUTPUT"
}
