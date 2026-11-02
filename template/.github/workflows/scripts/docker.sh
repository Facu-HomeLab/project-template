#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"

# ---------------------------------------------------------------------------
# Build and export Docker image
# ---------------------------------------------------------------------------

build_image() {
  local image="$1"
  local version="$2"
  local envname="$3"
  local dockerfile="$4"
  local context="$5"

  local image_tar
  local tmp_tar

  require_commands docker

  [[ -n "$image" ]] || die "Docker image name is required"
  [[ -n "$version" ]] || die "Image version is required"
  [[ -n "$envname" ]] || die "Environment name is required"

  [[ -f "$dockerfile" ]] ||
    die "Dockerfile does not exist: ${dockerfile}"

  [[ -d "$context" ]] ||
    die "Docker build context does not exist: ${context}"

  [[ -n "${RUNNER_TEMP:-}" && -d "$RUNNER_TEMP" && -w "$RUNNER_TEMP" ]] ||
    die "RUNNER_TEMP is unavailable or not writable"

  [[ -n "${GITHUB_SHA:-}" ]] ||
    die "GITHUB_SHA is required to label the image"

  [[ -n "${GITHUB_REPOSITORY:-}" ]] ||
    die "GITHUB_REPOSITORY is required to label the image"

  image_tar="${RUNNER_TEMP}/image.tar"
  tmp_tar="$(mktemp "${RUNNER_TEMP}/image.XXXXXX")"

  # Remove incomplete exports if the build or save operation fails.
  trap 'rm -f -- "${tmp_tar:-}"' RETURN

  log "Building Docker image: ${image}:${version}"

  docker build \
    --pull \
    --label "org.opencontainers.image.title=${image}" \
    --label "org.opencontainers.image.revision=${GITHUB_SHA}" \
    --label "org.opencontainers.image.source=https://github.com/${GITHUB_REPOSITORY}" \
    -f "$dockerfile" \
    -t "${image}:${version}" \
    "$context"

  log "Exporting Docker image to ${image_tar}"

  docker save \
    "${image}:${version}" \
    -o "$tmp_tar"

  [[ -s "$tmp_tar" ]] ||
    die "Docker image export is empty"

  # Atomic replacement of the artifact.
  mv -f -- "$tmp_tar" "$image_tar"

  log "Docker image built and exported successfully"
}