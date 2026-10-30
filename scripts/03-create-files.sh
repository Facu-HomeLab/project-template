
#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Project Template - Common Files Generator
# Version: 1.0.0
#
# Usage:
#   ./03-create-files.sh /opt/github/project-template
#   ./03-create-files.sh /opt/github/project-template --force
#
# Requirements:
#   Bash 4+
#
# Generates:
#   Docker Compose files
#   Environment example
#   Git / Docker ignore files
#   Editor configuration
#   Documentation
# ============================================================

SCRIPT_NAME="$(basename "$0")"
FORCE=false
TEMPLATE_DIR=""

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

if [[ ! -d "$TEMPLATE_DIR/deploy" ]]; then
    echo "[ERROR] Missing deploy directory."
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
        if [[ -t 0 ]]; then
            read -r -p "$relative_path already exists. Overwrite? [y/N]: " answer

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

    temporary_file="$(mktemp "$directory/.template.XXXXXX")"

    cat > "$temporary_file"

    mv "$temporary_file" "$destination"

    success "Generated: $relative_path"
}

# ------------------------------------------------------------
# Header
# ------------------------------------------------------------

echo
echo "================================================"
echo " Project Template - Common Files Generator"
echo "================================================"
echo
echo "Template: $TEMPLATE_DIR"
echo "Force overwrite: $FORCE"
echo

# ------------------------------------------------------------
# Docker Compose - Base
# ------------------------------------------------------------

write_file "deploy/docker-compose.yml" <<'EOF'
# ============================================================
# Docker Compose - Base Configuration
#
# Shared configuration for DEV and PROD.
# Image is built and published by GitHub Actions to Harbor.
# ============================================================

services:

  app:
    image: "${REGISTRY}/${HARBOR_PROJECT}/${IMAGE_NAME}:${IMAGE_TAG:-latest}"

    container_name: "${CONTAINER_NAME:-application}"

    restart: unless-stopped

    init: true

    stop_grace_period: 30s

    ports:
      - "${BIND_ADDRESS:-127.0.0.1}:${HOST_PORT:-3000}:${CONTAINER_PORT:-3000}"

    environment:
      APP_ENV: "${APP_ENV:-production}"
EOF

# ------------------------------------------------------------
# Docker Compose - DEV
# ------------------------------------------------------------

write_file "deploy/docker-compose.dev.yml" <<'EOF'
# ============================================================
# Docker Compose - Development Overrides
#
# Usage:
# docker compose \
#   -f deploy/docker-compose.yml \
#   -f deploy/docker-compose.dev.yml \
#   up -d
# ============================================================

services:

  app:
    environment:
      APP_ENV: development
EOF

# ------------------------------------------------------------
# Docker Compose - PROD
# ------------------------------------------------------------

write_file "deploy/docker-compose.prod.yml" <<'EOF'
# ============================================================
# Docker Compose - Production Overrides
#
# Usage:
# docker compose \
#   -f deploy/docker-compose.yml \
#   -f deploy/docker-compose.prod.yml \
#   up -d
# ============================================================

services:

  app:
    environment:
      APP_ENV: production
EOF

# ------------------------------------------------------------
# Caddy example
# ------------------------------------------------------------

write_file "deploy/Caddyfile.example" <<'EOF'
# ============================================================
# Caddy Reverse Proxy Example
#
# Adapt the upstream address to your actual network.
# This example assumes Caddy can reach the application
# through the host's loopback interface.
# ============================================================

{$APP_HOSTNAME} {
    reverse_proxy {$APP_UPSTREAM}
}
EOF

# ------------------------------------------------------------
# Environment example
# ------------------------------------------------------------

write_file ".env.example" <<'EOF'
# ============================================================
# Application Deployment Environment
#
# Copy this file to .env and adjust the values.
# Never commit .env or production secrets.
# ============================================================

# Harbor registry
REGISTRY=reg.internal.facuynati.website
HARBOR_PROJECT=applications

# Container
IMAGE_NAME=project-name
IMAGE_TAG=latest
CONTAINER_NAME=project-name

# Networking
BIND_ADDRESS=127.0.0.1
HOST_PORT=3000
CONTAINER_PORT=3000

# Application
APP_ENV=production

# Reverse proxy
APP_HOSTNAME=project-name.dev.facuynati.online
APP_UPSTREAM=127.0.0.1:3000
EOF

# ------------------------------------------------------------
# Git ignore
# ------------------------------------------------------------

write_file ".gitignore" <<'EOF'
# Environment files
.env
.env.*
!.env.example

# Dependencies
node_modules/
vendor/

# Python
__pycache__/
*.py[cod]
*.egg-info/
.venv/
venv/
.pytest_cache/
.mypy_cache/
.ruff_cache/

# Node / TypeScript
dist/
build/
.next/
.nuxt/
.turbo/
coverage/

# IDE
.idea/
.vscode/
*.swp
*.swo

# OS
.DS_Store
Thumbs.db

# Logs
*.log
logs/

# Temporary files
tmp/
temp/
.cache/

# Docker
*.tar
EOF

# ------------------------------------------------------------
# Docker ignore
# ------------------------------------------------------------

write_file ".dockerignore" <<'EOF'
.git
.github
.gitignore
.gitattributes
.env
.env.*
!.env.example

node_modules
vendor

.venv
venv
__pycache__
*.py[cod]
.pytest_cache
.mypy_cache
.ruff_cache

dist
build
.next
.nuxt
.turbo
coverage

.idea
.vscode
.DS_Store
Thumbs.db

*.log
logs
tmp
temp
.cache

tests
EOF

# ------------------------------------------------------------
# EditorConfig
# ------------------------------------------------------------

write_file ".editorconfig" <<'EOF'
root = true

[*]
charset = utf-8
end_of_line = lf
insert_final_newline = true
indent_style = space
indent_size = 2
trim_trailing_whitespace = true

[*.py]
indent_size = 4

[Makefile]
indent_style = tab

[*.md]
trim_trailing_whitespace = false
EOF

# ------------------------------------------------------------
# Git attributes
# ------------------------------------------------------------

write_file ".gitattributes" <<'EOF'
* text=auto

*.sh text eol=lf
*.yml text eol=lf
*.yaml text eol=lf
*.json text eol=lf
*.py text eol=lf
*.ts text eol=lf
*.tsx text eol=lf
*.js text eol=lf
*.md text eol=lf
Dockerfile text eol=lf
EOF

# ------------------------------------------------------------
# README
# ------------------------------------------------------------

write_file "README.md" <<'EOF'
# Project Name

Project description.

## Overview

Describe the purpose and functionality of this application.

## Technology Stack

Document the technologies used by this project.

## Requirements

- Docker
- Docker Compose v2
- Git

Additional requirements depend on the application stack.

## Configuration

Project configuration is maintained in:

`config/project.yaml`

Environment variables are documented in:

`.env.example`

Never commit credentials or production secrets.

## Local Development

1. Clone the repository.
2. Configure the required environment variables.
3. Build the application image using its Dockerfile.
4. Start the application using Docker Compose.

Example:

```bash
cp .env.example .env

docker compose \
  -f deploy/docker-compose.yml \
  -f deploy/docker-compose.dev.yml \
  up -d --build
```

Note: The Dockerfile must be implemented for the selected
technology before building the application.

## Deployment

Deployment is managed through GitHub Actions.

The deployment pipeline:

1. Runs CI checks.
2. Builds the Docker image.
3. Pushes the image to Harbor.
4. Deploys using Docker Compose.

Development and production deployments are configured
through their respective workflows.

## Healthcheck

Configure the application health endpoint according
to the implementation in `config/project.yaml`.

## License

Specify the project license.
EOF

# ------------------------------------------------------------
# CONTRIBUTING
# ------------------------------------------------------------

write_file "CONTRIBUTING.md" <<'EOF'
# Contributing

## Branch Strategy

- `test`: Integration and validation.
- `dev`: Development and DEV deployments.
- `main`: Production-ready code.

## Commit Convention

Recommended format:

```text
feat: add new functionality
fix: correct application behavior
docs: update documentation
refactor: improve internal structure
test: add or update tests
chore: maintenance tasks
```

## Pull Requests

- Keep changes focused.
- Run tests before submitting.
- Ensure CI checks pass.
- Include a clear description of the changes.

## Deployment

Deployments are managed through GitHub Actions
and the centralized CI/CD workflows.
EOF

# ------------------------------------------------------------
# Final summary
# ------------------------------------------------------------

echo
echo "================================================"
success "Common files generated successfully!"
echo "================================================"
echo

if command -v tree >/dev/null 2>&1; then
    tree -a "$TEMPLATE_DIR"
else
    find "$TEMPLATE_DIR" -print | sort
fi

echo
echo "Next step:"
echo "  04-create-workflows.sh"
echo
