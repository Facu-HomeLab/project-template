
#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Project Template - GitHub Workflows Generator
# Version: 1.0.0
#
# Usage:
#   ./04-create-workflows.sh /opt/github/project-template
#   ./04-create-workflows.sh /opt/github/project-template --force
#
# Generates:
#   .github/workflows/ci.yml
#   .github/workflows/deploy.yml
#   .github/workflows/runner-test.yml
#   .github/PULL_REQUEST_TEMPLATE.md
#
# Central reusable workflow:
#   Facu-HomeLab/.github
# ============================================================

SCRIPT_NAME="$(basename "$0")"
TEMPLATE_DIR=""
FORCE=false

# ------------------------------------------------------------
# Arguments
# ------------------------------------------------------------

for arg in "$@"; do
    case "$arg" in
        --force)
            FORCE=true
            ;;
        *)
            if [[ -z "$TEMPLATE_DIR" ]]; then
                TEMPLATE_DIR="$arg"
            else
                echo "Usage: $SCRIPT_NAME <template-directory> [--force]"
                exit 1
            fi
            ;;
    esac
done

if [[ -z "$TEMPLATE_DIR" ]]; then
    echo "Usage: $SCRIPT_NAME <template-directory> [--force]"
    exit 1
fi

TEMPLATE_DIR="${TEMPLATE_DIR%/}"

if [[ ! -d "$TEMPLATE_DIR" ]]; then
    echo "[ERROR] Template directory does not exist."
    exit 1
fi

if [[ ! -f "$TEMPLATE_DIR/config/project.yaml" ]]; then
    echo "[ERROR] Missing config/project.yaml."
    echo "Run 02-create-config.sh first."
    exit 1
fi

if [[ ! -d "$TEMPLATE_DIR/.github/workflows" ]]; then
    echo "[ERROR] Missing .github/workflows directory."
    echo "Run 01-create-structure.sh first."
    exit 1
fi

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

info() {
    echo -e "\033[0;34m[INFO]\033[0m $*"
}

success() {
    echo -e "\033[0;32m[OK]\033[0m $*"
}

warning() {
    echo -e "\033[0;33m[WARN]\033[0m $*"
}

write_file() {
    local relative_path="$1"
    local destination="$TEMPLATE_DIR/$relative_path"
    local directory
    local temporary_file

    directory="$(dirname "$destination")"
    mkdir -p "$directory"

    if [[ -f "$destination" && "$FORCE" != true ]]; then
        if [[ -t 0 && -r /dev/tty ]]; then
            read -r -p "$relative_path exists. Overwrite? [y/N]: " answer </dev/tty

            if [[ ! "$answer" =~ ^[Yy]$ ]]; then
                warning "Skipped: $relative_path"
                cat > /dev/null
                return 0
            fi
        else
            warning "Skipped existing file: $relative_path"
            cat > /dev/null
            return 0
        fi
    fi

    temporary_file="$(mktemp "$directory/.workflow.XXXXXX")"

    cat > "$temporary_file"

    mv "$temporary_file" "$destination"

    success "Generated: $relative_path"
}

# ------------------------------------------------------------
# Header
# ------------------------------------------------------------

echo
echo "================================================"
echo " GitHub Workflows Generator"
echo "================================================"
echo
echo "Template: $TEMPLATE_DIR"
echo "Force overwrite: $FORCE"
echo

# ============================================================
# 1. CI WORKFLOW
# ============================================================

write_file ".github/workflows/ci.yml" <<'EOF'
# ============================================================
# Continuous Integration
#
# Runs on:
#   - Push to test, dev and main
#   - Pull requests targeting test, dev and main
#
# This workflow uses GitHub-hosted runners.
# It does not deploy or publish images.
# ============================================================

name: CI

on:
  push:
    branches:
      - test
      - dev
      - main

  pull_request:
    branches:
      - test
      - dev
      - main

permissions:
  contents: read

concurrency:
  group: ci-${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:

  validate:
    name: Validate Docker build
    runs-on: ubuntu-latest
    timeout-minutes: 20

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Validate Dockerfile
        shell: bash
        run: |
          set -euo pipefail

          if [[ ! -f Dockerfile ]]; then
            echo "::error::Dockerfile not found."
            exit 1
          fi

          echo "Dockerfile found."

      - name: Build application image
        shell: bash
        run: |
          set -euo pipefail

          docker build \
            --label "org.opencontainers.image.source=https://github.com/$GITHUB_REPOSITORY" \
            --label "org.opencontainers.image.revision=$GITHUB_SHA" \
            -t "$GITHUB_REPOSITORY:ci-$GITHUB_SHA" \
            .

          echo "Docker build completed successfully."
EOF

# ============================================================
# 2. DEPLOY CALLER WORKFLOW
# ============================================================

write_file ".github/workflows/deploy.yml" <<'EOF'
# ============================================================
# Deployment Caller
#
# Central reusable workflow:
# Facu-HomeLab/.github
#
# Tag convention:
#   v1.2.3       -> PROD
#   v1.2.3-rc.1  -> STAGING
#   v1.2.3-dev.1 -> DEV
#
# Branch validation is performed by the central workflow.
# ============================================================

name: Deploy

on:
  push:
    tags:
      - "v*.*.*"

permissions:
  contents: read
  id-token: write

jobs:

  deploy:
    name: Build, publish and deploy

    uses: Facu-HomeLab/.github/.github/workflows/build-deploy.yml@v1

    with:
      dockerfile: Dockerfile
      context: .
      compose_file: deploy/docker-compose.yml
      timeout_minutes: 30

    # Uses the secrets and OIDC permissions of the caller.
    # OpenBao supplies deployment credentials.
EOF

# ============================================================
# 3. SELF-HOSTED RUNNER TEST
# ============================================================

write_file ".github/workflows/runner-test.yml" <<'EOF'
# ============================================================
# Self-hosted Runner Diagnostic
#
# Manual execution only.
#
# Expected runner labels:
#   self-hosted
#   linux
#   x64
#   ephemeral
#   docker
# ============================================================

name: Runner Test

on:
  workflow_dispatch:

permissions:
  contents: read

jobs:

  diagnostics:
    name: Check Proxmox Self-hosted Runner

    runs-on:
      - self-hosted
      - linux
      - x64
      - ephemeral
      - docker

    timeout-minutes: 10

    steps:

      - name: Checkout
        uses: actions/checkout@v4

      - name: Runner information
        shell: bash
        run: |
          set -euo pipefail

          echo "Hostname:"
          hostname

          echo "Operating system:"
          uname -a

          echo "User:"
          whoami

          echo "Working directory:"
          pwd

      - name: Verify required tools
        shell: bash
        run: |
          set -euo pipefail

          REQUIRED_TOOLS=(
            git
            bash
            curl
            jq
            docker
            ssh
            scp
          )

          for tool in "${REQUIRED_TOOLS[@]}"; do
            if ! command -v "$tool" >/dev/null 2>&1; then
              echo "::error::Missing required tool: $tool"
              exit 1
            fi

            echo "[OK] $tool"
          done

      - name: Verify Docker
        shell: bash
        run: |
          set -euo pipefail

          docker --version
          docker compose version
          docker info

          echo "Docker is operational."

      - name: Verify GitHub environment
        shell: bash
        run: |
          set -euo pipefail

          echo "Repository: $GITHUB_REPOSITORY"
          echo "Runner: $RUNNER_NAME"
          echo "Runner OS: $RUNNER_OS"
          echo "Runner architecture: $RUNNER_ARCH"

          echo "Runner diagnostics completed successfully."
EOF

# ============================================================
# 4. PULL REQUEST TEMPLATE
# ============================================================

write_file ".github/PULL_REQUEST_TEMPLATE.md" <<'EOF'
# Pull Request

## Description

Describe the changes introduced by this pull request.

## Type of change

- [ ] Feature
- [ ] Bug fix
- [ ] Refactoring
- [ ] Documentation
- [ ] Infrastructure / CI-CD

## Validation

- [ ] Tests completed
- [ ] Docker build successful
- [ ] CI checks passed
- [ ] Environment variables reviewed
- [ ] No secrets committed

## Additional notes

Add any additional context here.
EOF

# ============================================================
# FINAL SUMMARY
# ============================================================

echo
echo "================================================"
success "GitHub workflows generated successfully!"
echo "================================================"
echo

if command -v tree >/dev/null 2>&1; then
    tree -a "$TEMPLATE_DIR/.github"
else
    find "$TEMPLATE_DIR/.github" -print | sort
fi

echo
echo "Generated workflows:"
echo "  - CI"
echo "  - Deploy (central reusable workflow)"
echo "  - Runner Test"
echo
echo "Next step:"
echo "  Validate workflows and deployment configuration."
echo
