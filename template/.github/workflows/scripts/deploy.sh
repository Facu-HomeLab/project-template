#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ---------------------------------------------------------------------------
# Quote a value for safe use as a shell argument on the remote host
# ---------------------------------------------------------------------------

remote_quote() {
  local value="$1"

  # Escape single quotes using the standard POSIX shell sequence.
  value="${value//\'/\'\\\'\'}"

  printf "'%s'" "$value"
}

# ---------------------------------------------------------------------------
# Copy deployment files, validate Compose and deploy services remotely.
# All inputs come from the environment prepared by deploy_release().

deploy_compose() (
  local sshdir="${SSH_DIR:-}"
  local secrets="${SECRET_FILE:-}"
  local image="${IMAGE:-}"
  local version="${VERSION:-}"
  local slug="${REPO_SLUG:-}"
  local compose="${COMPOSE_FILE:-docker-compose.yml}"
  local extra="${EXTRA_FILES:-}"
  local registry="${HARBOR_REGISTRY:-}"
  local robot="${ROBOT_NAME:-}"
  local robotfile="${ROBOT_SECRET_FILE:-}"
  local verify="${VERIFY_HEALTH:-true}"
  local timeout="${HEALTH_TIMEOUT:-120}"

  local base
  local remote
  local qdir
  local qimage
  local qregistry
  local qrobot
  local filename
  local file
  local logged_in=0

  # -------------------------------------------------------------------------
  # Validate arguments and required files
  # -------------------------------------------------------------------------

  require_commands ssh scp docker

  [[ -d "$sshdir" && -r "${sshdir}/config" ]] ||
    die "SSH configuration is unavailable"

  [[ -r "$secrets" ]] ||
    die "Deployment secrets file is unavailable"

  [[ -f "$compose" && -r "$compose" ]] ||
    die "Compose file not found or unreadable: ${compose}"

  [[ -f "$robotfile" && -s "$robotfile" ]] ||
    die "Harbor robot secret file is missing or empty"

  [[ -n "$image" && -n "$version" && -n "$registry" && -n "$robot" ]] ||
    die "Image, version, registry and robot username are required"

  valid_dns_label "$slug" ||
    die "Invalid repository slug: ${slug}"

  valid_registry "$registry" ||
    die "Invalid Harbor registry: ${registry}"

  [[ "$verify" == true || "$verify" == false ]] ||
    die "Invalid VERIFY_HEALTH value: ${verify}"

  [[ "$timeout" =~ ^[1-9][0-9]{0,3}$ ]] ||
    die "Invalid HEALTH_TIMEOUT"

  # DEPLOY_PATH was validated by prepare_ssh().
  base="$(json_secret "$secrets" DEPLOY_PATH)"

  remote="${base%/}/${slug}"

  # Quote every variable used as a remote shell argument.
  qdir="$(remote_quote "$remote")"
  qimage="$(remote_quote "${image}:${version}")"
  qregistry="$(remote_quote "$registry")"
  qrobot="$(remote_quote "$robot")"

  # All remote commands run on the deployment target.
  rsh() {
    ssh -F "${sshdir}/config" target "$@"
  }

  # -------------------------------------------------------------------------
  # Remote cleanup
  # -------------------------------------------------------------------------

  cleanup_remote() {
    if (( logged_in )); then
      log "Logging out from Harbor on deployment host"

      rsh "docker logout ${qregistry} >/dev/null 2>&1 || true" ||
        warn "Remote Harbor logout failed"
    fi
  }

  trap cleanup_remote EXIT

  # -------------------------------------------------------------------------
  # Prepare remote deployment directory
  # -------------------------------------------------------------------------

  log "Preparing remote deployment directory: ${remote}"

  rsh "mkdir -p ${qdir}"

  # -------------------------------------------------------------------------
  # Copy Docker Compose configuration
  # -------------------------------------------------------------------------

  log "Copying Docker Compose configuration"

  scp -F "${sshdir}/config" \
    "$compose" \
    "target:${remote}/docker-compose.yml"

  # -------------------------------------------------------------------------
  # Copy additional deployment files
  #
  # EXTRA_FILES is a newline-separated list of local file paths.
  # Absolute paths and paths containing '..' components are rejected.
  # -------------------------------------------------------------------------

  if [[ -n "$extra" ]]; then
    while IFS= read -r file; do
      [[ -z "$file" ]] && continue

      [[ "$file" != /* ]] ||
        die "Absolute paths are not allowed in EXTRA_FILES: ${file}"

      [[ "$file" != ".." &&
         "$file" != ../* &&
         "$file" != */../* &&
         "$file" != */.. ]] ||
        die "Path traversal is not allowed in EXTRA_FILES: ${file}"

      [[ -f "$file" && -r "$file" ]] ||
        die "Additional deployment file not found or unreadable: ${file}"

      filename="$(basename -- "$file")"

      [[ "$filename" =~ ^[A-Za-z0-9._-]+$ ]] ||
        die "Invalid additional deployment filename: ${filename}"

      [[ "$filename" != "." && "$filename" != ".." ]] ||
        die "Invalid additional deployment filename: ${filename}"

      log "Copying additional deployment file: ${filename}"

      scp -F "${sshdir}/config" \
        "$file" \
        "target:${remote}/${filename}"

    done <<< "$extra"
  fi

  # -------------------------------------------------------------------------
  # Authenticate to Harbor on the remote deployment host
  # -------------------------------------------------------------------------

  log "Authenticating remote host to Harbor"

  rsh "docker login ${qregistry} -u ${qrobot} --password-stdin" \
    < "$robotfile"

  logged_in=1

  # -------------------------------------------------------------------------
  # Validate remote Docker Compose configuration
  # -------------------------------------------------------------------------

  log "Validating remote Docker Compose configuration"

  rsh "cd ${qdir} && IMAGE=${qimage} docker compose -f docker-compose.yml config -q"

  # -------------------------------------------------------------------------
  # Pull the immutable image version
  # -------------------------------------------------------------------------

  log "Pulling requested image: ${image}:${version}"

  rsh "cd ${qdir} && IMAGE=${qimage} docker compose -f docker-compose.yml pull"

  # -------------------------------------------------------------------------
  # Apply deployment
  # -------------------------------------------------------------------------

  log "Applying Docker Compose deployment (verify_health=${verify}, timeout=${timeout}s)"

  if [[ "$verify" == true ]]; then
    rsh "cd ${qdir} && IMAGE=${qimage} docker compose -f docker-compose.yml up -d --remove-orphans --wait --wait-timeout ${timeout}"
  else
    rsh "cd ${qdir} && IMAGE=${qimage} docker compose -f docker-compose.yml up -d --remove-orphans"
  fi

  # -------------------------------------------------------------------------
  # Display deployment status
  # -------------------------------------------------------------------------

  log "Checking deployed services"

  rsh "cd ${qdir} && IMAGE=${qimage} docker compose -f docker-compose.yml ps"

  log "Remote deployment completed successfully"
)

# ---------------------------------------------------------------------------
# Resolve release metadata and deploy the selected release
# ---------------------------------------------------------------------------

deploy_release() {
  local tag="${RELEASE_TAG:-}"

  local repository="${GITHUB_REPOSITORY:-}"
  local registry="${HARBOR_REGISTRY:-}"
  local secrets="${SECRET_FILE:-}"
  local sshdir="${SSH_DIR:-}"
  local robot_state="${ROBOT_STATE_FILE:-}"
  local robotfile="${ROBOT_SECRET_FILE:-}"

  # -------------------------------------------------------------------------
  # Validate required inputs
  # -------------------------------------------------------------------------

  [[ -n "$tag" ]] ||
    die "Release tag is required"

  [[ -n "$repository" ]] ||
    die "GITHUB_REPOSITORY is required"

  [[ -n "$registry" ]] ||
    die "HARBOR_REGISTRY is required"

  [[ -n "$secrets" && -r "$secrets" ]] ||
    die "Deployment secrets file is unavailable"

  [[ -n "$sshdir" && -d "$sshdir" ]] ||
    die "SSH configuration directory is unavailable"

  [[ -n "$robot_state" && -r "$robot_state" ]] ||
    die "Harbor robot state file is unavailable"

  [[ -n "$robotfile" && -s "$robotfile" ]] ||
    die "Harbor robot secret file is unavailable"

  # -------------------------------------------------------------------------
  # Resolve release metadata
  # -------------------------------------------------------------------------

  log "Resolving deployment metadata for release: ${tag}"

  resolve_release "$tag" "$repository" "$registry"

  [[ -n "${IMAGE:-}" ]] ||
    die "IMAGE was not resolved"

  [[ -n "${VERSION:-}" ]] ||
    die "VERSION was not resolved"

  [[ -n "${REPO_SLUG:-}" ]] ||
    die "REPO_SLUG was not resolved"

  # -------------------------------------------------------------------------
  # Read Harbor robot username from its state file
  # -------------------------------------------------------------------------

  ROBOT_NAME="$(json_secret "$robot_state" name)"

  [[ -n "$ROBOT_NAME" ]] ||
    die "Harbor robot username is missing"

  # -------------------------------------------------------------------------
  # Deployment configuration: step env > OpenBao secret > default
  # -------------------------------------------------------------------------

  config_value() {
    local env_name="$1" secret_name="$2" default="$3"
    local value
    value="${!env_name:-}"
    [[ -n "$value" ]] ||
      value="$(json_secret "$secrets" "$secret_name" 2>/dev/null || true)"
    printf '%s' "${value:-$default}"
  }

  COMPOSE_FILE="$(config_value COMPOSE_FILE COMPOSE_FILE docker-compose.yml)"
  EXTRA_FILES="$(config_value EXTRA_FILES DEPLOY_FILES '')"
  VERIFY_HEALTH="$(config_value VERIFY_HEALTH VERIFY_HEALTH true)"
  HEALTH_TIMEOUT="$(config_value HEALTH_TIMEOUT HEALTH_TIMEOUT 120)"

  export IMAGE VERSION REPO_SLUG ROBOT_NAME \
         COMPOSE_FILE EXTRA_FILES VERIFY_HEALTH HEALTH_TIMEOUT

  # -------------------------------------------------------------------------
  # Deploy
  # -------------------------------------------------------------------------

  log "Starting deployment"
  log "  Image:       ${IMAGE}"
  log "  Version:     ${VERSION}"
  log "  Repository:  ${REPO_SLUG}"
  log "  Registry:    ${registry}"
  log "  Compose:     ${COMPOSE_FILE}"
  log "  Health check: ${VERIFY_HEALTH}"
  log "  Timeout:     ${HEALTH_TIMEOUT}s"

  deploy_compose

  log "Release ${tag} deployed successfully"
}