#!/usr/bin/env bash
# Shared functions for the Facu-HomeLab reusable deployment workflow.
set -Eeuo pipefail

log()  { printf '[%s] %s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "$*" >&2; }
die()  { log "ERROR: $*"; exit 1; }
warn() { log "WARNING: $*"; }
require_commands() {
  local cmd
  for cmd in "$@"; do command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"; done
}
trim_slashes() { local v="$1"; v="${v#/}"; v="${v%/}"; printf '%s' "$v"; }
valid_identifier() { [[ "$1" =~ ^[a-z0-9][a-z0-9._-]{0,126}$ ]]; }

resolve_release() {
  local tag="$1"
  local repository="$2"
  local registry="$3"

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
    die "Unsupported tag '$tag'. Expected vX.Y.Z-dev.N, vX.Y.Z-rc.N or vX.Y.Z."
  fi

  VERSION="$tag"

  local repo owner

  owner="${repository%%/*}"
  repo="${repository#*/}"

  [[ "$owner" != "$repository" && -n "$repo" ]] \
    || die "Invalid GITHUB_REPOSITORY: $repository"

  REPO_SLUG="$(
    printf '%s' "$repo" \
      | tr '[:upper:]' '[:lower:]' \
      | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
  )"

  [[ -n "$REPO_SLUG" ]] || die "Could not normalize repository name"

  HARBOR_PROJECT="$(
    printf '%s-%s' "$owner" "$REPO_SLUG" \
      | tr '[:upper:]' '[:lower:]' \
      | sed -E 's/[^a-z0-9_-]+/-/g'
  )"

  valid_identifier "$HARBOR_PROJECT" \
    || die "Invalid normalized Harbor project: $HARBOR_PROJECT"

  IMAGE="$(trim_slashes "$registry")/${HARBOR_PROJECT}/${REPO_SLUG}"

  [[ "$IMAGE" != /* && "$IMAGE" != *' '* ]] \
    || die "Invalid image name: $IMAGE"

  export ENVIRONMENT BRANCH SECRET_DIR RELEASE_CHANNEL
  export VERSION REPO_SLUG HARBOR_PROJECT IMAGE

  log "Resolved release:"
  log "  Tag:         $VERSION"
  log "  Environment: $ENVIRONMENT"
  log "  Branch:      $BRANCH"
  log "  Secret dir:  $SECRET_DIR"
  log "  Channel:     $RELEASE_CHANNEL"
}

validate_release_branch() {
  local branch="$1"
  local sha="$2"
  local remote_ref="refs/remotes/origin/${branch}"

  log "Validating commit against branch '${branch}'..."

  git fetch --no-tags origin \
    "+refs/heads/${branch}:${remote_ref}" \
    || die "Could not fetch required branch '${branch}'."

  git merge-base --is-ancestor "$sha" "$remote_ref" \
    || die "Tag commit $sha is not contained in required branch '$branch'"

  log "Commit $sha is contained in branch '$branch'."
}

json_secret() {
  local file="$1" key="$2"
  [[ -r "$file" ]] || die "Secret file not readable: $file"
  jq -er --arg key "$key" '.[$key] | strings | select(length > 0)' "$file"
}
write_github_output() {
  [[ -n "${GITHUB_OUTPUT:-}" ]] || die "GITHUB_OUTPUT is not set"
  printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
}

# Resolve the OpenBao JWT role based on the target branch.
resolve_openbao_jwt_role() {
  local branch="${1:-${BRANCH:-}}"
  local jwt_role

  [[ -n "$branch" ]] || die "Branch is required to resolve OpenBao JWT role"
  [[ -n "${GITHUB_OUTPUT:-}" ]] || die "GITHUB_OUTPUT is not defined"

  case "$branch" in
    dev)
      jwt_role="gh-ci-dev"
      ;;
    test)
      jwt_role="gh-ci-test"
      ;;
    main|prod)
      jwt_role="gh-ci-prod"
      ;;
    *)
      die "No OpenBao JWT role configured for branch: $branch"
      ;;
  esac

  export jwt_role
  log "  jwt_role:         $jwt_role"

  echo "jwt_role=$jwt_role" >> "$GITHUB_OUTPUT"
}