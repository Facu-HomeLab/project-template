#!/usr/bin/env bash
set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Logging and error handling
# ---------------------------------------------------------------------------

log() {
  printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2
}

warn() {
  log "WARNING: $*"
}

die() {
  log "ERROR: $*"
  exit 1
}

# ---------------------------------------------------------------------------
# General utilities
# ---------------------------------------------------------------------------

require_commands() {
  local command_name

  for command_name in "$@"; do
    command -v "$command_name" >/dev/null 2>&1 ||
      die "Missing required command: ${command_name}"
  done
}

# Assert that every named script exists in the given directory.

require_scripts() {
  local dir="$1"
  shift

  [[ -n "$dir" ]] || die "Scripts directory is required"
  [[ -d "$dir" ]] || die "Scripts directory not found: ${dir}"

  local script
  for script in "$@"; do
    [[ -f "${dir}/${script}" ]] ||
      die "Missing required script: ${script}"
  done
}

trim_slashes() {
  local value="$1"

  value="${value#/}"
  value="${value%/}"

  printf '%s' "$value"
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

valid_dns_label() {
  [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

valid_registry() {
  local registry="$1"
  local hostname
  local port

  # Registry must be a hostname, optionally followed by a port.
  [[ "$registry" =~ ^[A-Za-z0-9.-]+(:[0-9]{1,5})?$ ]] ||
    return 1

  # Extract and validate port when provided.
  if [[ "$registry" == *:* ]]; then
    hostname="${registry%:*}"
    port="${registry##*:}"

    [[ -n "$hostname" ]] || return 1
    (( 10#$port >= 1 && 10#$port <= 65535 )) || return 1
  fi

  return 0
}

# ---------------------------------------------------------------------------
# Secrets
# ---------------------------------------------------------------------------

json_secret() {
  local file="$1"
  local key="$2"

  [[ -r "$file" ]] ||
    die "Secret file is unavailable or unreadable: ${file}"

  require_commands jq

  jq -er \
    --arg key "$key" \
    '.[$key] | strings | select(length > 0)' \
    "$file" ||
    die "Missing or invalid secret: ${key}"
}

# ---------------------------------------------------------------------------
# Release resolution
# ---------------------------------------------------------------------------

resolve_release() {
  local tag="$1"
  local repository="$2"
  local registry="$3"

  local owner
  local repo

  # Resolve environment from strict semantic version tags.
  if [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-dev\.(0|[1-9][0-9]*)$ ]]; then
    ENVIRONMENT="dev"
    BRANCH="dev"
    SECRET_DIR="Dev"
    RELEASE_CHANNEL="dev"

  elif [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)-rc\.(0|[1-9][0-9]*)$ ]]; then
    ENVIRONMENT="staging"
    BRANCH="main"
    SECRET_DIR="Staging"
    RELEASE_CHANNEL="staging"

  elif [[ "$tag" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    ENVIRONMENT="prod"
    BRANCH="main"
    SECRET_DIR="Prod"
    RELEASE_CHANNEL="prod"

  else
    die "Unsupported release tag: ${tag}"
  fi

  # Validate repository slug.
  [[ "$repository" == */* && "$repository" != */*/* ]] ||
    die "Invalid repository slug: ${repository}"

  owner="${repository%%/*}"
  repo="${repository#*/}"

  [[ -n "$owner" && -n "$repo" ]] ||
    die "Invalid repository owner or name"

  # Normalize repository name for the container image.
  REPO_SLUG="$(
    printf '%s' "$repo" |
      tr '[:upper:]' '[:lower:]' |
      sed -E 's/[^a-z0-9]+/-/g; s/^-|-$//g'
  )"

  [[ -n "$REPO_SLUG" ]] ||
    die "Repository name normalizes to an empty value"

  valid_dns_label "$REPO_SLUG" ||
    die "Invalid normalized repository name: ${REPO_SLUG}"

  # Validate Harbor registry.
  valid_registry "$registry" ||
    die "Invalid HARBOR_REGISTRY: ${registry}"

  # Resolve and normalize Harbor project.
  HARBOR_PROJECT="$(
    printf '%s' "${HARBOR_ORGANIZATION:-$owner}" |
      tr '[:upper:]' '[:lower:]' |
      sed -E 's/[^a-z0-9-]+/-/g; s/^-|-$//g'
  )"

  valid_dns_label "$HARBOR_PROJECT" ||
    die "Invalid Harbor project name: ${HARBOR_PROJECT}"

  # Construct immutable image reference.
  IMAGE="${registry}/${HARBOR_PROJECT}/${REPO_SLUG}"
  VERSION="$tag"

  # Export metadata for downstream scripts.
  export \
    ENVIRONMENT \
    BRANCH \
    SECRET_DIR \
    RELEASE_CHANNEL \
    REPO_SLUG \
    HARBOR_PROJECT \
    IMAGE \
    VERSION

  log "Release resolved:"
  log "  Tag: ${VERSION}"
  log "  Environment: ${ENVIRONMENT}"
  log "  Branch metadata: ${BRANCH}"
  log "  Secret directory: ${SECRET_DIR}"
  log "  Harbor project: ${HARBOR_PROJECT}"
  log "  Image: ${IMAGE}"
}

# ---------------------------------------------------------------------------
# Optional release branch validation
# ---------------------------------------------------------------------------

validate_release_branch() {
  local branch="$1"
  local sha="$2"
  local ref="refs/remotes/origin/${branch}"

  [[ -n "$branch" ]] ||
    die "Branch name is required"

  [[ "$sha" =~ ^[a-fA-F0-9]{40}$ ]] ||
    die "Invalid commit SHA: ${sha}"

  require_commands git

  log "Checking whether commit belongs to branch '${branch}'"

  git fetch --no-tags origin \
    "+refs/heads/${branch}:${ref}" >/dev/null ||
    die "Unable to fetch branch: ${branch}"

  git merge-base --is-ancestor "$sha" "$ref" ||
    die "Commit ${sha} is not contained in branch '${branch}'"

  log "Source commit validated: ${sha:0:12}"
}

# ---------------------------------------------------------------------------
# OpenBao JWT role resolution
# ---------------------------------------------------------------------------

resolve_openbao_jwt_role() {
  case "$1" in
    dev)
      printf '%s' "gh-ci-dev"
      ;;
    staging)
      printf '%s' "gh-ci-staging"
      ;;
    prod)
      printf '%s' "gh-ci-prod"
      ;;
    *)
      die "Unknown environment for OpenBao role: $1"
      ;;
  esac
}

# -----------------------------------------------------------------------------
# CI validation
# -----------------------------------------------------------------------------

ci_validate_bash_scripts() {
  local scripts_dir=".github/workflows/scripts"
  local -a scripts=()

  log "Validating Bash scripts"

  [[ -d "$scripts_dir" ]] || die "Scripts directory not found: $scripts_dir"

  require_commands find

  mapfile -d '' scripts < <(
    find "$scripts_dir" -type f -name '*.sh' -print0
  )

  ((${#scripts[@]} > 0)) || die "No Bash scripts found in $scripts_dir"

  local file
  for file in "${scripts[@]}"; do
    log "Checking syntax: $file"
    bash -n "$file" || die "Bash syntax error: $file"
  done

  # Install ShellCheck only when it is not available.
  if ! command -v shellcheck >/dev/null 2>&1; then
    require_commands sudo apt-get
    log "Installing ShellCheck"
    sudo apt-get update -qq
    sudo apt-get install -y -qq shellcheck
  fi

  log "Running ShellCheck"
  shellcheck -S warning "${scripts[@]}" ||
    die "ShellCheck reported issues"

  log "Bash validation passed"
}

ci_validate_yaml() {
  local workflows_dir=".github/workflows"
  local -a yaml_files=()

  log "Validating workflow YAML files"

  [[ -d "$workflows_dir" ]] ||
    die "Workflow directory not found: $workflows_dir"

  require_commands find ruby

  mapfile -d '' yaml_files < <(
    find "$workflows_dir" -type f \
      \( -name '*.yml' -o -name '*.yaml' \) -print0
  )

  ((${#yaml_files[@]} > 0)) ||
    die "No workflow YAML files found"

  ruby -e '
    require "yaml"

    ARGV.each do |file|
      YAML.load_file(file, aliases: true)
      puts "YAML OK: #{file}"
    end
  ' "${yaml_files[@]}" || die "YAML validation failed"

  log "YAML validation passed"
}

ci_test_release_resolver() {
  log "Testing release resolver"

  local HARBOR_ORGANIZATION="Facu-HomeLab"

  resolve_release \
    "v1.2.3-dev.4" \
    "Facu-HomeLab/my-project" \
    "registry.example.com"

  [[ "$ENVIRONMENT" == "dev" ]] ||
    die "Incorrect dev environment resolution"

  [[ "$BRANCH" == "dev" ]] ||
    die "Incorrect dev branch resolution"

  [[ "$HARBOR_PROJECT" == "facu-homelab" ]] ||
    die "Incorrect Harbor project resolution"

  [[ "$IMAGE" == "registry.example.com/facu-homelab/my-project" ]] ||
    die "Incorrect Docker image resolution"

  resolve_release \
    "v1.2.3-rc.2" \
    "Facu-HomeLab/my-project" \
    "registry.example.com"

  [[ "$ENVIRONMENT" == "staging" && "$BRANCH" == "main" ]] ||
    die "Incorrect staging release resolution"

  resolve_release \
    "v1.2.3" \
    "Facu-HomeLab/my-project" \
    "registry.example.com"

  [[ "$ENVIRONMENT" == "prod" && "$BRANCH" == "main" ]] ||
    die "Incorrect production release resolution"

  if ( resolve_release \
    "v1.2.3-beta.1" \
    "Facu-HomeLab/my-project" \
    "registry.example.com" >/dev/null 2>&1
  ); then
    die "Invalid release tag was accepted"
  fi

  log "Release resolver tests passed"
}

ci_build_docker_image() {
  local image_tag

  log "Validating Docker build"

  require_commands docker

  [[ -f Dockerfile ]] ||
    die "Dockerfile not found"

  [[ -n "${GITHUB_SHA:-}" ]] ||
    die "GITHUB_SHA is not defined"

  [[ -n "${GITHUB_REPOSITORY:-}" ]] ||
    die "GITHUB_REPOSITORY is not defined"

  image_tag="ci:${GITHUB_SHA}"

  docker build \
    --label "org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY}" \
    --label "org.opencontainers.image.revision=${GITHUB_SHA}" \
    --tag "$image_tag" \
    .

  log "Docker build passed: $image_tag"
}

ci_validate_repository() {
  log "Starting repository CI validation"

  ci_validate_bash_scripts
  ci_validate_yaml
  ci_test_release_resolver
  ci_build_docker_image

  log "All CI validation checks passed"
}