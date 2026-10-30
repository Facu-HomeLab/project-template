
#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Project Template - Configuration Generator
# Version: 1.0.0
#
# Usage:
#   ./02-create-config.sh /opt/github/project-template
#
# Requirements:
#   Bash 4+
#
# Output:
#   config/project.yaml
# ============================================================

SCRIPT_NAME="$(basename "$0")"

# ------------------------------------------------------------
# Helpers
# ------------------------------------------------------------

info()    { echo -e "\033[0;34m[INFO]\033[0m $*"; }
success() { echo -e "\033[0;32m[OK]\033[0m $*"; }
warning() { echo -e "\033[0;33m[WARN]\033[0m $*"; }
error()   { echo -e "\033[0;31m[ERROR]\033[0m $*" >&2; }

prompt() {
    local label="$1"
    local default="$2"
    local value

    if [[ -n "$default" ]]; then
        read -r -p "$label [$default]: " value
        echo "${value:-$default}"
    else
        read -r -p "$label: " value
        echo "$value"
    fi
}

validate_slug() {
    [[ "$1" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

validate_domain() {
    [[ "$1" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

validate_port() {
    [[ "$1" =~ ^[0-9]+$ ]] &&
    (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

# Escape strings for YAML single-quoted values.
yaml_quote() {
    local value="$1"
    value="${value//\'/\'\'}"
    printf "'%s'" "$value"
}

# ------------------------------------------------------------
# Arguments
# ------------------------------------------------------------

if [[ $# -ne 1 ]]; then
    echo "Usage: $SCRIPT_NAME <template-directory>"
    echo
    echo "Example:"
    echo "  $SCRIPT_NAME /opt/github/project-template"
    exit 1
fi

TEMPLATE_DIR="${1%/}"

if [[ ! -d "$TEMPLATE_DIR" ]]; then
    error "Template directory does not exist: $TEMPLATE_DIR"
    exit 1
fi

CONFIG_DIR="$TEMPLATE_DIR/config"
CONFIG_FILE="$CONFIG_DIR/project.yaml"

if [[ ! -d "$CONFIG_DIR" ]]; then
    error "Missing config directory. Run 01-create-structure.sh first."
    exit 1
fi

# ------------------------------------------------------------
# Header
# ------------------------------------------------------------

echo
echo "================================================"
echo " Project Template - Configuration Generator"
echo "================================================"
echo
echo "Template: $TEMPLATE_DIR"
echo

# ------------------------------------------------------------
# Existing configuration
# ------------------------------------------------------------

if [[ -f "$CONFIG_FILE" ]]; then
    warning "Configuration already exists: $CONFIG_FILE"
    read -r -p "Overwrite existing configuration? [y/N]: " overwrite

    if [[ ! "$overwrite" =~ ^[Yy]$ ]]; then
        info "Operation cancelled."
        exit 0
    fi
fi

# ------------------------------------------------------------
# Project information
# ------------------------------------------------------------

echo
echo "========== PROJECT INFORMATION =========="

while true; do
    PROJECT_NAME="$(prompt "Project name (slug)" "")"

    if validate_slug "$PROJECT_NAME"; then
        break
    fi

    error "Use lowercase letters, numbers and hyphens."
done

PROJECT_DESCRIPTION="$(prompt "Project description" "Application")"

GITHUB_ORG="$(prompt "GitHub organization" "my-github-org")"

REPOSITORY="$(prompt "Repository name" "$PROJECT_NAME")"

if ! validate_slug "$REPOSITORY"; then
    error "Invalid repository slug."
    exit 1
fi

# ------------------------------------------------------------
# Container information
# ------------------------------------------------------------

echo
echo "========== CONTAINER CONFIGURATION =========="

REGISTRY="$(prompt "Docker registry" "reg.internal.facuynati.website")"

HARBOR_PROJECT="$(prompt "Harbor project" "applications")"

IMAGE_NAME="$(prompt "Docker image name" "$PROJECT_NAME")"

if ! validate_slug "$IMAGE_NAME"; then
    error "Invalid Docker image name."
    exit 1
fi

while true; do
    APP_PORT="$(prompt "Application port" "3000")"

    if validate_port "$APP_PORT"; then
        break
    fi

    error "Port must be between 1 and 65535."
done

# ------------------------------------------------------------
# Deployment configuration
# ------------------------------------------------------------

echo
echo "========== DEPLOYMENT CONFIGURATION =========="

while true; do
    BASE_DOMAIN="$(prompt "Base domain" "facuynati.online")"

    if validate_domain "$BASE_DOMAIN"; then
        break
    fi

    error "Invalid domain."
done

DEV_HOSTNAME="$(prompt "DEV hostname" "$PROJECT_NAME.dev.$BASE_DOMAIN")"

PROD_HOSTNAME="$(prompt "PROD hostname" "$PROJECT_NAME.$BASE_DOMAIN")"

if ! validate_domain "$DEV_HOSTNAME" ||
   ! validate_domain "$PROD_HOSTNAME"; then
    error "Invalid deployment hostname."
    exit 1
fi

DEV_TARGET="$(prompt "DEV deployment target" "proxmox-dev")"

PROD_TARGET="$(prompt "PROD deployment target" "proxmox-prod")"

DEV_ENABLED="true"
PROD_ENABLED="true"

read -r -p "Enable DEV deployment? [Y/n]: " answer
[[ "$answer" =~ ^[Nn]$ ]] && DEV_ENABLED="false"

read -r -p "Enable PROD deployment? [Y/n]: " answer
[[ "$answer" =~ ^[Nn]$ ]] && PROD_ENABLED="false"

# ------------------------------------------------------------
# Healthcheck
# ------------------------------------------------------------

echo
echo "========== HEALTHCHECK CONFIGURATION =========="

HEALTHCHECK_PATH="$(prompt "Healthcheck path" "/health")"

HEALTHCHECK_INTERVAL="$(prompt "Healthcheck interval (seconds)" "30")"

if [[ ! "$HEALTHCHECK_PATH" =~ ^/[a-zA-Z0-9/_-]*$ ]]; then
    error "Invalid healthcheck path."
    exit 1
fi

if [[ ! "$HEALTHCHECK_INTERVAL" =~ ^[0-9]+$ ]] ||
   (( 10#$HEALTHCHECK_INTERVAL < 1 )); then
    error "Invalid healthcheck interval."
    exit 1
fi

# ------------------------------------------------------------
# Generate YAML
# ------------------------------------------------------------

mkdir -p "$CONFIG_DIR"

TEMP_FILE="$(mktemp "$CONFIG_DIR/.project.yaml.XXXXXX")"

cleanup() {
    [[ -n "${TEMP_FILE:-}" ]] && rm -f "$TEMP_FILE"
}

trap cleanup EXIT

cat > "$TEMP_FILE" <<EOF
# ============================================================
# Project Configuration
# Generated by: 02-create-config.sh
#
# This file is the central configuration source for:
# - Docker Compose
# - GitHub Actions
# - Deployment automation
# ============================================================

project:
  name: $(yaml_quote "$PROJECT_NAME")
  description: $(yaml_quote "$PROJECT_DESCRIPTION")
  repository: $(yaml_quote "$REPOSITORY")
  organization: $(yaml_quote "$GITHUB_ORG")

container:
  registry: $(yaml_quote "$REGISTRY")
  harbor_project: $(yaml_quote "$HARBOR_PROJECT")
  image: $(yaml_quote "$IMAGE_NAME")
  port: $APP_PORT

deployment:
  provider: docker-compose

  dev:
    enabled: $DEV_ENABLED
    hostname: $(yaml_quote "$DEV_HOSTNAME")
    environment: development
    target: $(yaml_quote "$DEV_TARGET")

  prod:
    enabled: $PROD_ENABLED
    hostname: $(yaml_quote "$PROD_HOSTNAME")
    environment: production
    target: $(yaml_quote "$PROD_TARGET")

healthcheck:
  path: $(yaml_quote "$HEALTHCHECK_PATH")
  interval: $HEALTHCHECK_INTERVAL
EOF

mv "$TEMP_FILE" "$CONFIG_FILE"
TEMP_FILE=""

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------

echo
echo "================================================"
success "Configuration generated successfully!"
echo "================================================"
echo
echo "File: $CONFIG_FILE"
echo

cat "$CONFIG_FILE"

echo
echo "Next step:"
echo "  Implement Docker Compose using project.yaml"
echo
