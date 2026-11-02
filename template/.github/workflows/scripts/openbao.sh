#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# OpenBao authentication and secret retrieval
# ---------------------------------------------------------------------------

bao_read() {
  local addr="$1"
  local role="$2"
  local audience="$3"
  local path="$4"
  local out="$5"

  local jwt=""
  local token=""
  local status=""
  local body=""
  local secret_path=""

  # Validate arguments.
  [[ -n "$addr" ]] ||
    die "OpenBao address is required"

  [[ "$addr" =~ ^https://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/.*)?$ ]] ||
    die "BAO_ADDR must be a valid HTTPS URL"

  [[ -n "$role" ]] ||
    die "OpenBao JWT role is required"

  [[ -n "$audience" ]] ||
    die "OpenBao JWT audience is required"

  [[ -n "$path" ]] ||
    die "OpenBao secret path is required"

  [[ -n "$out" ]] ||
    die "Output file is required"

  [[ -d "$(dirname -- "$out")" ]] ||
    die "Output directory does not exist"

  require_commands curl jq

  # Validate GitHub Actions OIDC environment.
  [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" &&
     -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]] ||
    die "GitHub OIDC is not available in this job"

  # Prepare private temporary response file.
  umask 077
  body="$(mktemp)"

  # Ensure temporary data is removed and OpenBao token revoked
  # if the function exits unexpectedly.
  trap '
    if [[ -n "${token:-}" ]]; then
      curl --silent --show-error --fail \
        -X POST \
        -H "X-Vault-Token: ${token}" \
        -H "Content-Type: application/json" \
        --data "{}" \
        "${addr%/}/v1/auth/token/revoke-self" >/dev/null ||
        warn "OpenBao token revocation failed; TTL remains the fallback"
    fi

    unset token jwt
    [[ -n "${body:-}" ]] && rm -f -- "$body"
  ' EXIT

  # -------------------------------------------------------------------------
  # 1. Request GitHub OIDC token
  # -------------------------------------------------------------------------

  log "Requesting short-lived GitHub OIDC token"

  status="$(
    curl \
      --silent \
      --show-error \
      --output "$body" \
      --write-out '%{http_code}' \
      -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
      "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=$(jq -rn --arg value "$audience" '$value | @uri')"
  )" || die "GitHub OIDC endpoint request failed"

  [[ "$status" =~ ^2[0-9][0-9]$ ]] ||
    die "GitHub OIDC returned HTTP ${status}"

  jwt="$(jq -er '.value | strings | select(length > 0)' "$body")" ||
    die "Unable to extract GitHub OIDC token"

  # Clear the response containing the JWT.
  : > "$body"

  # -------------------------------------------------------------------------
  # 2. Authenticate to OpenBao using JWT
  # -------------------------------------------------------------------------

  log "Authenticating to OpenBao using role '${role}'"

  status="$(
    curl \
      --silent \
      --show-error \
      --output "$body" \
      --write-out '%{http_code}' \
      -H "Content-Type: application/json" \
      --data "$(jq -n --arg role "$role" --arg jwt "$jwt" \
        '{role: $role, jwt: $jwt}')" \
      "${addr%/}/v1/auth/jwt/login"
  )" || die "OpenBao login request failed"

  unset jwt

  [[ "$status" =~ ^2[0-9][0-9]$ ]] ||
    die "OpenBao login returned HTTP ${status}"

  token="$(jq -er '.auth.client_token | strings | select(length > 0)' "$body")" ||
    die "Unable to extract OpenBao client token"

  # Clear the response containing authentication data.
  : > "$body"

  # -------------------------------------------------------------------------
  # 3. Read environment secrets from OpenBao KV v2
  # -------------------------------------------------------------------------

  secret_path="$(trim_slashes "$path")"

  [[ -n "$secret_path" ]] ||
    die "Invalid OpenBao secret path"

  log "Reading OpenBao KV path '${secret_path}'"

  status="$(
    curl \
      --silent \
      --show-error \
      --output "$body" \
      --write-out '%{http_code}' \
      -H "X-Vault-Token: ${token}" \
      "${addr%/}/v1/${secret_path}"
  )" || die "OpenBao KV request failed"

  [[ "$status" =~ ^2[0-9][0-9]$ ]] ||
    die "OpenBao KV read returned HTTP ${status}"

  # Validate expected KV v2 response structure.
  jq -e '.data.data | type == "object"' "$body" >/dev/null ||
    die "Unexpected OpenBao KV v2 response"

  # -------------------------------------------------------------------------
  # 4. Write secrets to protected JSON file
  # -------------------------------------------------------------------------

  jq '.data.data' "$body" > "$out" ||
    die "Unable to write OpenBao secrets to output file"

  chmod 600 "$out"

  # Clear response data from temporary file.
  : > "$body"

  # -------------------------------------------------------------------------
  # 5. Revoke short-lived OpenBao token
  # -------------------------------------------------------------------------

  log "Revoking short-lived OpenBao token"

  curl \
    --silent \
    --show-error \
    --fail \
    -X POST \
    -H "X-Vault-Token: ${token}" \
    -H "Content-Type: application/json" \
    --data '{}' \
    "${addr%/}/v1/auth/token/revoke-self" >/dev/null ||
    warn "OpenBao token revocation failed; TTL remains the fallback"

  unset token

  # Remove temporary response file and trap.
  rm -f -- "$body"
  body=""
  trap - EXIT

  log "OpenBao secrets successfully written to protected file"

  printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# Standalone execution
# ---------------------------------------------------------------------------

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ $# == 5 ]] ||
    die "Usage: openbao.sh <addr> <role> <audience> <path> <output-file>"

  bao_read "$@"
fi

# ---------------------------------------------------------------------------
# Environment configuration loader
# ---------------------------------------------------------------------------

openbao_load_environment_config() {
  local environment="$1"
  local bao_addr="$2"
  local bao_path_prefix="$3"
  local bao_audience="$4"
  local jwt_role="$5"
  local github_output="$6"

  local secret_dir=""
  local secret_path=""
  local state_dir=""
  local secret_file=""

  # -------------------------------------------------------------------------
  # 1. Validate required arguments
  # -------------------------------------------------------------------------

  [[ -n "$environment" ]] ||
    die "Environment is required"

  [[ -n "$bao_addr" ]] ||
    die "BAO_ADDR is required"

  [[ -n "$bao_path_prefix" ]] ||
    die "BAO_PATH_PREFIX is required"

  [[ -n "$bao_audience" ]] ||
    die "BAO_AUDIENCE is required"

  [[ -n "$jwt_role" ]] ||
    die "OpenBao JWT role is required"

  [[ -n "$github_output" ]] ||
    die "GITHUB_OUTPUT path is required"

  [[ -n "${RUNNER_TEMP:-}" ]] ||
    die "RUNNER_TEMP is not set"

  [[ -d "$RUNNER_TEMP" && -w "$RUNNER_TEMP" ]] ||
    die "RUNNER_TEMP is not writable"

  [[ -f "$github_output" && -w "$github_output" ]] ||
    die "GITHUB_OUTPUT is unavailable or not writable"

  # -------------------------------------------------------------------------
  # 2. Resolve environment-specific OpenBao secret directory
  # -------------------------------------------------------------------------

  case "$environment" in
    dev)
      secret_dir="Dev"
      ;;
    staging)
      secret_dir="Staging"
      ;;
    prod)
      secret_dir="Prod"
      ;;
    *)
      die "Unsupported environment: ${environment}"
      ;;
  esac

  secret_path="${bao_path_prefix%/}/${secret_dir}"

  # -------------------------------------------------------------------------
  # 3. Create protected temporary state directory
  # -------------------------------------------------------------------------

  state_dir="${RUNNER_TEMP}/ci-cd-state"

  mkdir -p "$state_dir"
  chmod 700 "$state_dir"

  # Create a unique secret file.
  umask 077

  secret_file="$(mktemp "${state_dir}/openbao.XXXXXX.json")"
  chmod 600 "$secret_file"

  # -------------------------------------------------------------------------
  # 4. Authenticate and retrieve environment secrets
  # -------------------------------------------------------------------------

  log "Loading OpenBao configuration for environment '${environment}'"

  if ! bao_read \
    "$bao_addr" \
    "$jwt_role" \
    "$bao_audience" \
    "$secret_path" \
    "$secret_file" >/dev/null; then

    rm -f -- "$secret_file"
    die "Failed to load OpenBao configuration"
  fi

  # -------------------------------------------------------------------------
  # 5. Export only the secret file path to GitHub Actions
  # -------------------------------------------------------------------------

  printf 'secret_file=%s\n' "$secret_file" >> "$github_output" ||
    {
      rm -f -- "$secret_file"
      die "Unable to write secret_file output to GITHUB_OUTPUT"
    }

  log "OpenBao configuration loaded for environment '${environment}'"
}