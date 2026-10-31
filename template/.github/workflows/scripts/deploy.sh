#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

deploy_compose() {
  local secret_file="$1" ssh_dir="$2" image="$3" version="$4" repo_slug="$5"
  local compose_file="$6" deploy_files="$7" verify_health="$8" health_timeout="$9"
  local registry="${10}" robot_name="${11}" robot_secret_file="${12}"
  local deploy_path remote_dir remote_user robot_secret
  deploy_path="$(json_secret "$secret_file" DEPLOY_PATH)"
  remote_user="$(json_secret "$secret_file" DEPLOY_USER)"
  remote_dir="${deploy_path%/}/${repo_slug}"
  [[ -f "$compose_file" ]] || die "Compose file not found: $compose_file"
  ssh -F "$ssh_dir/config" deploy-target "mkdir -p '$remote_dir'"
  scp -F "$ssh_dir/config" "$compose_file" "deploy-target:$remote_dir/docker-compose.yml"
  local file
  while IFS= read -r file; do
    [[ -z "$file" ]] && continue
    [[ "$file" != /* && "$file" != *".."* && -f "$file" ]] || die "Invalid deploy_files entry: $file"
    scp -F "$ssh_dir/config" "$file" "deploy-target:$remote_dir/$(basename "$file")"
  done <<< "$deploy_files"

  robot_secret="$(<"$robot_secret_file")"
  printf '%s' "$robot_secret" | ssh -F "$ssh_dir/config" deploy-target \
    "docker login '$registry' -u '$robot_name' --password-stdin"
  unset robot_secret
  ssh -F "$ssh_dir/config" deploy-target "cd '$remote_dir' && IMAGE='$image:$version' docker compose -f docker-compose.yml config -q"
  ssh -F "$ssh_dir/config" deploy-target "cd '$remote_dir' && IMAGE='$image:$version' docker compose -f docker-compose.yml pull"
  ssh -F "$ssh_dir/config" deploy-target "cd '$remote_dir' && IMAGE='$image:$version' docker compose -f docker-compose.yml up -d --remove-orphans"
  ssh -F "$ssh_dir/config" deploy-target "cd '$remote_dir' && IMAGE='$image:$version' docker compose -f docker-compose.yml ps"
  if [[ "$verify_health" == "true" ]]; then
    ssh -F "$ssh_dir/config" deploy-target "cd '$remote_dir' && IMAGE='$image:$version' timeout '$health_timeout' sh -c 'until [ -n \"\$(docker compose -f docker-compose.yml ps --status running -q)\" ]; do sleep 3; done'"
    log "Compose containers are running. Define Docker HEALTHCHECK in the image/compose service for health-state verification."
  fi
  ssh -F "$ssh_dir/config" deploy-target "docker logout '$registry' >/dev/null 2>&1 || true"
}
