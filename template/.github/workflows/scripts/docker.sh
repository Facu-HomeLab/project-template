#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

build_push() {
  local image="$1" version="$2" environment="$3" dockerfile="$4" context="$5" robot_name="$6" robot_secret_file="$7"
  unset DOCKER_CONTEXT
  log "  require_commands docker!!"
  require_commands docker
  [[ -f "$dockerfile" ]] || die "Dockerfile not found: $dockerfile"
  [[ -d "$context" ]] || die "Build context not found: $context"
  local secret
  secret="$(<"$robot_secret_file")"
  printf '%s' "$secret" | docker login "${image%%/*}" -u "$robot_name" --password-stdin
  unset secret
  local tags=("$version" "$environment")
  [[ "$environment" == "prod" ]] && tags+=("latest")
  local args=( --pull -f "$dockerfile" -t "$image:$version" "$context")
  log "  docker build $args"
  docker build "${args[@]}"
  local tag
  for tag in "${tags[@]}"; do
    [[ "$tag" == "$version" ]] || docker tag "$image:$version" "$image:$tag"
    docker push "$image:$tag"
  done
  local digest
  digest="$(docker inspect --format='{{index .RepoDigests 0}}' "$image:$version" 2>/dev/null || true)"
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    printf 'published_tags=%s\nimage_digest=%s\n' "$(IFS=,; echo "${tags[*]}")" "$digest" >> "$GITHUB_OUTPUT"
  fi
}
