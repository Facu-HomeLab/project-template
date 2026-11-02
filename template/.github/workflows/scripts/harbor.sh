#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh"

# ---------------------------------------------------------------------------
# Harbor REST API
# ---------------------------------------------------------------------------

harbor_api() {
  local method="$1"
  local url="$2"
  local user="$3"
  local pass="$4"
  local data="${5:-}"

  require_commands curl

  [[ -n "$method" ]] || die "Harbor HTTP method is required"
  [[ -n "$url" ]] || die "Harbor API URL is required"
  [[ -n "$user" && -n "$pass" ]] ||
    die "Harbor API credentials are required"

  case "$method" in
    GET|POST|PUT|PATCH|DELETE) ;;
    *) die "Unsupported Harbor HTTP method: ${method}" ;;
  esac

  if [[ -n "$data" ]]; then
    printf '%s' "$data" |
      curl \
        --silent \
        --show-error \
        --fail \
        -X "$method" \
        --user "${user}:${pass}" \
        -H 'Content-Type: application/json' \
        --data-binary @- \
        "$url"
  else
    curl \
      --silent \
      --show-error \
      --fail \
      -X "$method" \
      --user "${user}:${pass}" \
      "$url"
  fi
}

# ---------------------------------------------------------------------------
# Harbor administrative credentials
# ---------------------------------------------------------------------------

harbor_credentials() {
  local secrets="$1"

  [[ -n "$secrets" && -r "$secrets" ]] ||
    die "Harbor secrets file is unavailable or unreadable"

  require_commands jq

  HARBOR_USER="$(json_secret "$secrets" HARBOR_ADMIN_USERNAME)"
  HARBOR_PASS="$(json_secret "$secrets" HARBOR_ADMIN_PASSWORD)"

  [[ -n "$HARBOR_USER" && -n "$HARBOR_PASS" ]] ||
    die "Harbor administrative credentials are empty"
}

# Resolve the Harbor project name: HARBOR_ORGANIZATION from the secret file,
# falling back to the repository owner, normalized the same way
# resolve_release() does. Result exported as HARBOR_PROJECT.

harbor_project() {
  local secrets="$1"
  local org

  org="$(json_secret "$secrets" HARBOR_ORGANIZATION 2>/dev/null || true)"
  [[ -n "$org" ]] || org="${GITHUB_REPOSITORY%%/*}"

  HARBOR_PROJECT="$(
    printf '%s' "$org" |
      tr '[:upper:]' '[:lower:]' |
      sed -E 's/[^a-z0-9-]+/-/g; s/^-|-$//g'
  )"

  valid_dns_label "$HARBOR_PROJECT" ||
    die "Invalid Harbor project name: ${HARBOR_PROJECT}"

  export HARBOR_PROJECT
}

# ---------------------------------------------------------------------------
# Ensure private Harbor project exists
# ---------------------------------------------------------------------------

ensure_project() {
  local base="$1"
  local project="$2"
  local secrets="$3"

  local status
  local body
  local tmp

  [[ -n "$base" ]] || die "Harbor base URL is required"
  [[ -n "$project" ]] || die "Harbor project name is required"

  valid_dns_label "$project" ||
    die "Invalid Harbor project name: ${project}"

  require_commands curl jq

  harbor_credentials "$secrets"

  tmp="$(mktemp)"
  trap 'rm -f -- "${tmp:-}"' RETURN

  # Check whether the project already exists.
  log "Checking Harbor project '${project}'"

  status="$(
    curl \
      --silent \
      --show-error \
      --output "$tmp" \
      --write-out '%{http_code}' \
      --user "${HARBOR_USER}:${HARBOR_PASS}" \
      "${base%/}/api/v2.0/projects/${project}"
  )" || die "Harbor project lookup failed (network/TLS)"

  case "$status" in
    200)
      # Existing projects must be private.
      jq -e '
        (.metadata.public == false) or
        (.metadata.public == "false")
      ' "$tmp" >/dev/null ||
        die "Harbor project '${project}' exists but is not private"

      log "Harbor project '${project}' already exists and is private"
      ;;

    404)
      # Create the project with public access disabled.
      local body
      body="$(
        jq -n \
          --arg name "$project" \
          '{
            project_name: $name,
            public: false,
            metadata: {
              public: "false"
            }
          }'
      )"

      if harbor_api POST \
        "${base%/}/api/v2.0/projects" \
        "$HARBOR_USER" \
        "$HARBOR_PASS" \
        "$body" >/dev/null; then

        log "Created private Harbor project '${project}'"

      else
        # A concurrent workflow may have created the project.
        status="$(
          curl \
            --silent \
            --show-error \
            --output "$tmp" \
            --write-out '%{http_code}' \
            --user "${HARBOR_USER}:${HARBOR_PASS}" \
            "${base%/}/api/v2.0/projects/${project}"
        )" || die "Unable to verify Harbor project after creation conflict"

        [[ "$status" == "200" ]] ||
          die "Unable to create Harbor project '${project}'"

        jq -e '
          (.metadata.public == false) or
          (.metadata.public == "false")
        ' "$tmp" >/dev/null ||
          die "Harbor project '${project}' exists but is not private"

        log "Harbor project '${project}' was created by another process"
      fi
      ;;

    *)
      die "Harbor project lookup returned HTTP ${status}"
      ;;
  esac
}

# ---------------------------------------------------------------------------
# Create temporary Harbor robot account
# ---------------------------------------------------------------------------

create_robot() {
  local base="$1"
  local project="$2"
  local secrets="$3"
  local name="$4"
  local scope="$5"
  local secret_out="$6"
  local state_out="$7"

  local body
  local response
  local id
  local robot_name
  local robot_secret

  [[ -n "$base" ]] || die "Harbor base URL is required"
  [[ -n "$project" ]] || die "Harbor project is required"
  [[ -n "$name" ]] || die "Harbor robot name is required"
  [[ -n "$secret_out" && -n "$state_out" ]] ||
    die "Robot output paths are required"

  valid_dns_label "$project" ||
    die "Invalid Harbor project name: ${project}"

  case "$scope" in
    push|pull) ;;
    *) die "Invalid Harbor robot scope: ${scope}; expected push or pull" ;;
  esac

  [[ -n "${GITHUB_OUTPUT:-}" && -w "${GITHUB_OUTPUT}" ]] ||
    die "GITHUB_OUTPUT is unavailable or not writable"

  require_commands jq

  [[ -d "$(dirname -- "$secret_out")" ]] ||
    die "Robot secret output directory does not exist"

  [[ -d "$(dirname -- "$state_out")" ]] ||
    die "Robot state output directory does not exist"

  harbor_credentials "$secrets"

  # Define the minimum permissions required for this workflow.
  body="$(
    jq -n \
      --arg name "$name" \
      --arg project "$project" \
      --arg scope "$scope" \
      '{
        name: $name,
        description: "Temporary GitHub Actions robot",
        duration: 1,
        level: "project",
        permissions: [
          {
            kind: "project",
            namespace: $project,
            access: (
              if $scope == "push" then
                [
                  {resource: "repository", action: "pull"},
                  {resource: "repository", action: "push"}
                ]
              else
                [
                  {resource: "repository", action: "pull"}
                ]
              end
            )
          }
        ]
      }'
  )"

  log "Creating temporary Harbor robot (scope=${scope})"

  response="$(
    harbor_api POST \
      "${base%/}/api/v2.0/robots" \
      "$HARBOR_USER" \
      "$HARBOR_PASS" \
      "$body"
  )" || die "Unable to create Harbor robot"

  # Extract the robot credentials.
  id="$(jq -er '.id' <<< "$response")" ||
    die "Harbor response does not contain a robot ID"

  robot_name="$(jq -er '.name' <<< "$response")" ||
    die "Harbor response does not contain a robot name"

  robot_secret="$(jq -er '.secret | strings | select(length > 0)' <<< "$response")" ||
    die "Harbor response does not contain a robot secret"

  # Save robot state immediately so cleanup can identify the robot.
  umask 077

  jq -n \
    --arg id "$id" \
    --arg name "$robot_name" \
    '{id: $id, name: $name}' > "$state_out" ||
    die "Unable to write Harbor robot state"

  chmod 600 "$state_out"

  # Save the secret separately from the state metadata.
  printf '%s' "$robot_secret" > "$secret_out" ||
    die "Unable to write Harbor robot secret"

  chmod 600 "$secret_out"

  # Mask the secret in GitHub Actions logs.
  printf '::add-mask::%s\n' "$robot_secret"

  unset robot_secret response body

  # Publish file paths and non-secret metadata to subsequent steps.
  {
    printf 'robot_name=%s\n' "$robot_name"
    printf 'robot_secret_file=%s\n' "$secret_out"
    printf 'robot_state_file=%s\n' "$state_out"
    printf 'robot_id=%s\n' "$id"
  } >> "$GITHUB_OUTPUT" ||
    die "Unable to write Harbor robot outputs"

  log "Temporary Harbor robot created (id=${id}, scope=${scope})"
}

# ---------------------------------------------------------------------------
# Delete temporary Harbor robot
# ---------------------------------------------------------------------------

delete_robot() {
  local base="$1"
  local secrets="$2"
  local state="$3"

  local id
  local status

  # Nothing to delete if no robot state was generated.
  [[ -s "$state" ]] || {
    log "No Harbor robot state found; skipping deletion"
    return 0
  }

  require_commands curl jq

  harbor_credentials "$secrets"

  id="$(jq -er '.id | tostring | select(length > 0)' "$state")" ||
    die "Invalid Harbor robot state file"

  [[ "$id" =~ ^[0-9]+$ ]] ||
    die "Invalid Harbor robot ID: ${id}"

  log "Deleting temporary Harbor robot (id=${id})"

  status="$(
    curl \
      --silent \
      --show-error \
      --output /dev/null \
      --write-out '%{http_code}' \
      --user "${HARBOR_USER}:${HARBOR_PASS}" \
      -X DELETE \
      "${base%/}/api/v2.0/robots/${id}"
  )" || die "Harbor robot deletion request failed"

  case "$status" in
    200|202|204|404)
      log "Temporary Harbor robot deleted or already absent (id=${id})"
      ;;
    *)
      die "Harbor robot deletion returned HTTP ${status}"
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Ensure the Harbor project and repository for IMAGE exist
# -----------------------------------------------------------------------------

harbor_ensure_image_target() {
  local image="${1:-${IMAGE:-}}"
  local secrets="${2:-${SECRET_FILE:-}}"
  local registry image_path project repository base encoded_repository status tmp

  [[ -n "$image" ]] || die "IMAGE is not defined"
  [[ -n "$secrets" && -r "$secrets" ]] ||
    die "Harbor credentials file is unavailable"
  [[ "$image" == */* ]] || die "Invalid IMAGE: registry is missing"

  registry="${image%%/*}"
  image_path="${image#*/}"
  [[ "$image_path" == */* ]] ||
    die "Invalid IMAGE: expected <registry>/<project>/<repository>"

  project="${image_path%%/*}"
  repository="${image_path#*/}"
  [[ -n "$project" && -n "$repository" && "$repository" != */ ]] ||
    die "Invalid IMAGE path: expected <registry>/<project>/<repository>"

  # Harbor project names must be lowercase DNS-style labels. For the GitHub
  # organization Facu-HomeLab, use the Harbor project name facu-homelab.
  valid_dns_label "$project" ||
    die "Invalid Harbor project name '${project}'. Use lowercase, e.g. facu-homelab"
  [[ "$repository" =~ ^[a-z0-9]+([._-][a-z0-9]+)*((/[a-z0-9]+([._-][a-z0-9]+)*)*)?$ ]] ||
    die "Invalid Harbor repository name: ${repository}"

  valid_registry "$registry" || die "Invalid Harbor registry: ${registry}"
  base="${HARBOR_URL:-https://${registry}}"

  # Ensure the private project exists first. This function creates it when
  # the Harbor API returns 404 and verifies that existing projects are private.
  ensure_project "$base" "$project" "$secrets"

  # Harbor creates a repository automatically on the first successful push;
  # this API check is informational and verifies access before publishing.
  harbor_credentials "$secrets"
  encoded_repository="$(jq -rn --arg value "$repository" '$value|@uri')"
  tmp="$(mktemp)"
  trap 'rm -f -- "${tmp:-}"' RETURN

  status="$(curl --silent --show-error \
    --output "$tmp" \
    --write-out '%{http_code}' \
    --user "${HARBOR_USER}:${HARBOR_PASS}" \
    "${base%/}/api/v2.0/projects/${project}/repositories/${encoded_repository}")" ||
    die "Harbor repository lookup failed (network/TLS)"

  unset HARBOR_PASS

  case "$status" in
    200)
      log "Harbor repository '${project}/${repository}' already exists"
      ;;
    404)
      log "Harbor repository '${project}/${repository}' does not exist yet; the first successful docker push will create it"
      ;;
    *)
      die "Harbor repository lookup returned HTTP ${status}: $(cat "$tmp")"
      ;;
  esac
}

# -----------------------------------------------------------------------------
# Docker authentication and image publishing
# -----------------------------------------------------------------------------

harbor_login() {
  log "Authenticating Docker with Harbor"

  require_commands docker jq

  [[ -n "${SECRET_FILE:-}" ]] ||
    die "SECRET_FILE is not defined"

  [[ -n "${IMAGE:-}" ]] ||
    die "IMAGE is not defined"

  [[ "$IMAGE" == */* ]] ||
    die "Invalid IMAGE: registry is missing"

  local registry="${IMAGE%%/*}"

  valid_registry "$registry" ||
    die "Invalid Harbor registry: $registry"

  [[ -r "$SECRET_FILE" ]] ||
    die "Harbor credentials file is unavailable"

  # Create the Harbor project if needed and check whether the repository exists.
  harbor_ensure_image_target "$IMAGE" "$SECRET_FILE"

  harbor_credentials "$SECRET_FILE"

  [[ -n "$HARBOR_USER" && -n "$HARBOR_PASS" ]] ||
    die "Harbor credentials are empty"

  if ! printf '%s' "$HARBOR_PASS" |
    docker login "$registry" \
      --username "$HARBOR_USER" \
      --password-stdin; then
    unset HARBOR_PASS
    die "Docker authentication with Harbor failed"
  fi

  unset HARBOR_PASS

  HARBOR_LOGIN_REGISTRY="$registry"
  export HARBOR_LOGIN_REGISTRY

  log "Successfully authenticated with Harbor: $registry"
}

harbor_push() {
  set -Eeuo pipefail

  local version="${1:-}"
  local image="${IMAGE:-}"
  local environment="${ENVIRONMENT:-}"
  local registry="${HARBOR_LOGIN_REGISTRY:-}"

  [[ -n "$version" ]] ||
    die "Release version is required"

  [[ -n "$image" ]] ||
    die "IMAGE is not defined"

  [[ -n "$environment" ]] ||
    die "ENVIRONMENT is not defined"

  [[ -n "$registry" ]] ||
    die "Harbor authentication has not been initialized"

  [[ "$image" == "$registry/"* ]] ||
    die "IMAGE registry does not match authenticated registry"

  [[ "$version" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-(dev|rc)\.(0|[1-9][0-9]*))?$ ]] ||
    die "Invalid release version: $version"

  case "$environment" in
    dev|staging|prod) ;;
    *) die "Unsupported environment: $environment" ;;
  esac

  local source_image="${image}:${version}"
  local -a tags=("$version" "$environment" "${image##*/}")

  [[ "$environment" == "prod" ]] && tags+=("latest")

  # Always logout, including when a push fails.
  printf -v logout_command \
  'docker logout %q >/dev/null 2>&1 || true' \
  "$registry"

  trap "$logout_command" EXIT

  docker image inspect "$source_image" >/dev/null 2>&1 ||
    die "Source image not found: $source_image"

  log "Publishing image: $source_image"

  local tag
  for tag in "${tags[@]}"; do
    log "Publishing tag: ${image}:${tag}"

    if [[ "$tag" != "$version" ]]; then
      docker tag "$source_image" "${image}:${tag}"
    fi

    docker push "${image}:${tag}" ||
      die "Failed to push image tag: ${image}:${tag}"
  done

  log "Successfully published all Harbor tags"
  }
