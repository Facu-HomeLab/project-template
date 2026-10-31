#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

bao_request() {
  local operation="$1"
  local url="$2"
  shift 2

  local body_file error_file status
  body_file="$(mktemp)"
  error_file="$(mktemp)"

  if ! status="$(curl --silent --show-error \
      --output "$body_file" \
      --write-out '%{http_code}' \
      "$@" "$url" 2>"$error_file")"; then
    log "ERROR: OpenBao request failed during: $operation"
    cat "$error_file" >&2
    rm -f "$body_file" "$error_file"
    die "Network or TLS error during $operation"
  fi

  if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
    log "ERROR: OpenBao returned HTTP $status during: $operation"

    local api_error
    api_error="$(jq -r '.errors // empty | if type == "array" then join("; ") else tostring end' \
      "$body_file" 2>/dev/null || true)"

    [[ -n "$api_error" ]] && log "OpenBao message: $api_error"

    rm -f "$body_file" "$error_file"
    die "OpenBao request failed: $operation (HTTP $status)"
  fi

  RESPONSE_BODY="$(cat "$body_file")"
  rm -f "$body_file" "$error_file"
}


bao_login_and_read() {
  local addr="$1"
  local role="$2"
  local audience="$3"
  local path="$4"

  require_commands curl jq

  [[ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" &&
     -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]] \
    || die "GitHub OIDC request environment is unavailable"

  local jwt token secret_file
  local login_response read_response
  local token_accessor
  local body_file error_file status api_error

  # --------------------------------------------------
  # 1. GitHub Actions OIDC token
  # --------------------------------------------------

  log "Requesting GitHub Actions OIDC token..."

  body_file="$(mktemp)"
  error_file="$(mktemp)"

  if ! status="$(curl --silent --show-error \
      --output "$body_file" \
      --write-out '%{http_code}' \
      -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
      "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=$(jq -rn --arg v "$audience" '$v|@uri')" \
      2>"$error_file")"; then

    log "ERROR: GitHub OIDC request failed"
    cat "$error_file" >&2
    rm -f "$body_file" "$error_file"
    die "Could not obtain GitHub Actions OIDC token"
  fi

  if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
    log "ERROR: GitHub OIDC returned HTTP $status"

    api_error="$(jq -r '.message // .error // empty' \
      "$body_file" 2>/dev/null || true)"

    [[ -n "$api_error" ]] && log "Response: $api_error"

    rm -f "$body_file" "$error_file"
    die "GitHub OIDC token request failed (HTTP $status)"
  fi

  jwt="$(jq -er '.value' "$body_file")"
  rm -f "$body_file" "$error_file"

  [[ -n "$jwt" ]] || die "GitHub OIDC returned an empty JWT"

  # --------------------------------------------------
  # 2. OpenBao JWT authentication
  # --------------------------------------------------

  log "Authenticating with OpenBao JWT role '${role}'..."

  body_file="$(mktemp)"
  error_file="$(mktemp)"

  if ! status="$(curl --silent --show-error \
      --output "$body_file" \
      --write-out '%{http_code}' \
      -H 'Content-Type: application/json' \
      --data "$(jq -n \
        --arg role "$role" \
        --arg jwt "$jwt" \
        '{role:$role,jwt:$jwt}')" \
      "${addr%/}/v1/auth/jwt/login" \
      2>"$error_file")"; then

    log "ERROR: OpenBao JWT authentication request failed"
    cat "$error_file" >&2
    rm -f "$body_file" "$error_file"
    unset jwt
    die "Could not authenticate with OpenBao"
  fi

  if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
    log "ERROR: OpenBao JWT login returned HTTP $status"

    api_error="$(jq -r '.errors // empty |
      if type == "array" then join("; ") else tostring end' \
      "$body_file" 2>/dev/null || true)"

    [[ -n "$api_error" ]] && log "OpenBao message: $api_error"

    rm -f "$body_file" "$error_file"
    unset jwt
    die "OpenBao JWT authentication failed (HTTP $status)"
  fi

  login_response="$(cat "$body_file")"
  rm -f "$body_file" "$error_file"

  token="$(jq -er '.auth.client_token' <<<"$login_response")"
  token_accessor="$(jq -er '.auth.accessor // empty' <<<"$login_response")"

  [[ -n "$token" ]] || die "OpenBao login did not return a client token"

  unset jwt login_response

  # --------------------------------------------------
  # 3. Read KV v2 secret
  # --------------------------------------------------

  log "Reading OpenBao secret: ${path}"

  body_file="$(mktemp)"
  error_file="$(mktemp)"

  if ! status="$(curl --silent --show-error \
      --output "$body_file" \
      --write-out '%{http_code}' \
      -H "X-Vault-Token: $token" \
      "${addr%/}/v1/$(trim_slashes "$path")" \
      2>"$error_file")"; then

    log "ERROR: OpenBao KV request failed"
    cat "$error_file" >&2
    rm -f "$body_file" "$error_file"
    unset token
    die "Could not read OpenBao secret"
  fi

  if [[ ! "$status" =~ ^2[0-9][0-9]$ ]]; then
    log "ERROR: OpenBao KV read returned HTTP $status"

    api_error="$(jq -r '.errors // empty |
      if type == "array" then join("; ") else tostring end' \
      "$body_file" 2>/dev/null || true)"

    [[ -n "$api_error" ]] && log "OpenBao message: $api_error"

    rm -f "$body_file" "$error_file"
    unset token
    die "OpenBao KV read failed (HTTP $status)"
  fi

  read_response="$(cat "$body_file")"
  rm -f "$body_file" "$error_file"

  jq -e '.data.data | type == "object"' \
    >/dev/null <<<"$read_response" \
    || {
      unset token
      die "OpenBao KV v2 response did not contain data.data"
    }

  # --------------------------------------------------
  # 4. Save secrets to temporary JSON file
  # --------------------------------------------------

  secret_file="${RUNNER_TEMP:-/tmp}/openbao-secrets-${GITHUB_RUN_ID:-manual}-${GITHUB_RUN_ATTEMPT:-1}.json"

  umask 077

  jq '.data.data' <<<"$read_response" > "$secret_file"
  chmod 600 "$secret_file"

  unset read_response

  # --------------------------------------------------
  # 5. Validate required secrets
  # --------------------------------------------------

  local required

  for required in \
    HARBOR_ADMIN_USERNAME \
    HARBOR_ADMIN_PASSWORD \
    DEPLOY_SSH_KEY \
    DEPLOY_KNOWN_HOSTS \
    DEPLOY_HOST \
    DEPLOY_USER \
    DEPLOY_PATH
  do
    json_secret "$secret_file" "$required" >/dev/null \
      || {
        unset token
        die "Missing required OpenBao key: $required"
      }
  done

  # --------------------------------------------------
  # 6. Revoke OpenBao token
  # --------------------------------------------------

  log "Revoking temporary OpenBao token..."

  if ! curl --fail --silent --show-error \
      -X POST \
      -H "X-Vault-Token: $token" \
      -H 'Content-Type: application/json' \
      --data '{}' \
      "${addr%/}/v1/auth/token/revoke-self" \
      >/dev/null; then

    warn "Could not revoke OpenBao token; its configured TTL remains the fallback"
  fi

  unset token token_accessor

  log "OpenBao authentication and secret retrieval completed successfully."

  printf '%s\n' "$secret_file"
}


if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  [[ $# -eq 4 ]] || die "Usage: openbao.sh <bao_addr> <jwt_role> <audience> <secret_path>"
  bao_login_and_read "$1" "$2" "$3" "$4"
fi
