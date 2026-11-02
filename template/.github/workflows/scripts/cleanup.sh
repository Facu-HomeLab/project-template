#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ---------------------------------------------------------------------------
# Logout from Docker registry and remove local temporary files
# ---------------------------------------------------------------------------

cleanup_runner() {
  local registry="${1:-}"
  local dir="${2:-}"

  require_commands docker

  [[ -n "$registry" ]] ||
    die "Docker registry is required"

  valid_registry "$registry" ||
    die "Invalid Docker registry: ${registry}"

  # Logout is best-effort: the job may not have authenticated.
  log "Logging out from Docker registry: ${registry}"

  if ! docker logout "$registry" >/dev/null 2>&1; then
    warn "Docker logout failed or no active session exists"
  fi

  # Nothing else to remove if no directory was provided.
  if [[ -z "$dir" ]]; then
    log "No temporary directory specified; skipping file cleanup"
    return 0
  fi

  # Resolve the directory before deleting it.
  if [[ ! -e "$dir" ]]; then
    log "Temporary directory does not exist; nothing to remove"
    return 0
  fi

  [[ -d "$dir" && ! -L "$dir" ]] ||
    die "Cleanup target is not a valid directory: ${dir}"

  local target
  target="$(cd -- "$dir" && pwd -P)" ||
    die "Unable to resolve cleanup directory"

  [[ "$target" != "/" ]] ||
    die "Refusing to delete filesystem root"

  [[ -n "${RUNNER_TEMP:-}" && -d "$RUNNER_TEMP" ]] ||
    die "RUNNER_TEMP is unavailable; cannot validate cleanup target"

  local runner_temp
  runner_temp="$(cd -- "$RUNNER_TEMP" && pwd -P)" ||
    die "Unable to resolve RUNNER_TEMP"

  # Only remove directories inside RUNNER_TEMP.
  [[ "$target" == "$runner_temp/"* ]] ||
    die "Refusing to delete directory outside RUNNER_TEMP: ${target}"

  log "Removing local temporary directory: ${target}"

  rm -rf -- "$target"

  log "Local temporary credentials and files cleaned up"
}