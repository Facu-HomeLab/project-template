#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

cleanup_all() {
  local bao_addr="$1" harbor_url="$2" secret_file="$3" robot_state="$4" robot_secret="$5" ssh_dir="$6" registry="$7"
  set +e
  docker logout "$registry" >/dev/null 2>&1
  if [[ -n "$secret_file" && -s "$secret_file" ]]; then
    if [[ -n "$ssh_dir" && -f "$ssh_dir/config" ]]; then
      ssh -F "$ssh_dir/config" deploy-target "docker logout '$registry' >/dev/null 2>&1 || true" >/dev/null 2>&1
    fi
    if [[ -n "$robot_state" && -s "$robot_state" ]]; then
      source "$SCRIPT_DIR/harbor.sh"
      delete_robot "$harbor_url" "$secret_file" "$robot_state" || warn "Could not delete temporary Harbor robot"
    fi
  fi
  [[ -n "$ssh_dir" ]] && rm -rf -- "$ssh_dir"
  [[ -n "$secret_file" ]] && rm -f -- "$secret_file"
  [[ -n "$robot_secret" ]] && rm -f -- "$robot_secret"
  [[ -n "$robot_state" ]] && rm -f -- "$robot_state"
  rm -f "${RUNNER_TEMP:-/tmp}"/harbor-project-check.* 2>/dev/null
  set -e
}
