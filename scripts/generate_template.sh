#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ORG="Facu-HomeLab"
SOURCE_REPO="${SOURCE_REPO:-https://github.com/${ORG}/project-template.git}"
SOURCE_BRANCH="${SOURCE_BRANCH:-main}"

# Shared values baked into .env, config/project.yaml and the Docker Compose
# files. Change them here, never in the individual bake calls below.
REGISTRY="reg.internal.facuynati.website"
HARBOR_PROJECT="applications"
IMAGE_TAG="latest"
BIND_ADDRESS="127.0.0.1"
HOST_PORT="3000"
CONTAINER_PORT="80"

usage() {
  cat <<'USAGE'
Usage:
  ./generate_template.sh
  ./generate_template.sh --name NAME --description TEXT \
    --dev-hostname HOST --prod-hostname HOST \
    --dev-target TARGET --prod-target TARGET

Options:
  --name NAME              Project/repository name
  --description TEXT       Project description
  --dev-hostname HOST      Development hostname
  --prod-hostname HOST     Production hostname
  --dev-target TARGET      Development deployment target
  --prod-target TARGET     Production deployment target
  -h, --help               Show this help

Interactive mode offers defaults; press Enter to accept one.
In CLI mode all six options are required.
The script creates ./$NAME, which must not already exist.

Dependencies: bash, gh, git, and standard Unix utilities.
USAGE
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }
need_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

# bake FILE MATCH LINE — replace with LINE the single line that contains MATCH.
# Dies unless MATCH is found exactly once; every templated value is filled
# through here, so a drifting template fails loudly instead of silently.
bake() {
  local file="$1" match="$2" line="$3"
  local count=0 tmp="${file}.bake.tmp" l
  : > "$tmp"
  while IFS= read -r l || [[ -n "$l" ]]; do
    if [[ "$l" == *"$match"* ]]; then
      ((count += 1))
      printf '%s\n' "$line" >> "$tmp"
    else
      printf '%s\n' "$l" >> "$tmp"
    fi
  done < "$file"
  ((count == 1)) ||
    { rm -f "$tmp"; die "$file: expected exactly one line containing '$match', found $count."; }
  mv "$tmp" "$file"
}

validate_single_line() {
  local label="$1" value="$2"
  [[ -n "${value//[[:space:]]/}" ]] || die "$label cannot be empty."
  [[ "$value" != *$'\n'* && "$value" != *$'\r'* ]] || die "$label must be a single line."
}
validate_project_name() {
  [[ "$1" =~ ^[A-Za-z0-9._-]+$ && "$1" != "." && "$1" != ".." && "$1" != -* ]] ||
    die "Invalid project name '$1'. Use letters, numbers, '.', '_' or '-'."
}
validate_hostname() {
  local label="$1" value="$2"
  validate_single_line "$label" "$value"
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
    die "$label must be a hostname without scheme, path, or port."
  [[ "$value" != *..* && "$value" != *.-* && "$value" != *-. ]] ||
    die "$label contains an invalid hostname sequence."
}
prompt_value() {
  local var_name="$1" label="$2" default="$3" value=""
  while true; do
    read -r -p "${label} [${default}]: " value
    value="${value:-$default}"
    if [[ -n "${value//[[:space:]]/}" ]]; then
      printf -v "$var_name" '%s' "$value"
      return
    fi
    printf 'This field is required.\n' >&2
  done
}

PROJECT_NAME=""
DESCRIPTION=""
DEV_HOSTNAME=""
PROD_HOSTNAME=""
DEV_TARGET=""
PROD_TARGET=""
CLI_MODE=false
# Track seen CLI options without associative arrays (Bash 3.2 compatible)
SEEN_NAME=0
SEEN_DESCRIPTION=0
SEEN_DEV_HOSTNAME=0
SEEN_PROD_HOSTNAME=0
SEEN_DEV_TARGET=0
SEEN_PROD_TARGET=0

while (($#)); do
  case "$1" in
    --name|--description|--dev-hostname|--prod-hostname|--dev-target|--prod-target)
      (($# >= 2)) || die "$1 requires a value"
      key="$1"; value="$2"
      case "$key" in
        --name) PROJECT_NAME="$value"; SEEN_NAME=1 ;;
        --description) DESCRIPTION="$value"; SEEN_DESCRIPTION=1 ;;
        --dev-hostname) DEV_HOSTNAME="$value"; SEEN_DEV_HOSTNAME=1 ;;
        --prod-hostname) PROD_HOSTNAME="$value"; SEEN_PROD_HOSTNAME=1 ;;
        --dev-target) DEV_TARGET="$value"; SEEN_DEV_TARGET=1 ;;
        --prod-target) PROD_TARGET="$value"; SEEN_PROD_TARGET=1 ;;
      esac
      CLI_MODE=true
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

need_command gh
need_command git
gh auth status >/dev/null 2>&1 || die "GitHub CLI is not authenticated. Run: gh auth login."
gh api "orgs/${ORG}" >/dev/null 2>&1 ||
  die "Cannot access organization ${ORG}; check membership and permissions."

if [[ "$CLI_MODE" == false ]]; then
  prompt_value PROJECT_NAME "Project name" "my-project"
  validate_project_name "$PROJECT_NAME"
  prompt_value DESCRIPTION "Project description" "$PROJECT_NAME"
  prompt_value DEV_HOSTNAME "Development hostname" "${PROJECT_NAME}.dev.facuynati.website"
  prompt_value PROD_HOSTNAME "Production hostname" "${PROJECT_NAME}.facuynati.website"
  prompt_value DEV_TARGET "Development deployment target" "proxmox-dev"
  prompt_value PROD_TARGET "Production deployment target" "proxmox-prod"
else
  [[ $SEEN_NAME -eq 1 ]] || die "CLI mode requires --name."
  [[ $SEEN_DESCRIPTION -eq 1 ]] || die "CLI mode requires --description."
  [[ $SEEN_DEV_HOSTNAME -eq 1 ]] || die "CLI mode requires --dev-hostname."
  [[ $SEEN_PROD_HOSTNAME -eq 1 ]] || die "CLI mode requires --prod-hostname."
  [[ $SEEN_DEV_TARGET -eq 1 ]] || die "CLI mode requires --dev-target."
  [[ $SEEN_PROD_TARGET -eq 1 ]] || die "CLI mode requires --prod-target."
fi

validate_project_name "$PROJECT_NAME"
validate_single_line "Description" "$DESCRIPTION"
validate_hostname "Development hostname" "$DEV_HOSTNAME"
validate_hostname "Production hostname" "$PROD_HOSTNAME"
validate_single_line "Development target" "$DEV_TARGET"
validate_single_line "Production target" "$PROD_TARGET"

REPO_FULL_NAME="${ORG}/${PROJECT_NAME}"
TARGET_DIR="${PWD}/${PROJECT_NAME}"
[[ ! -e "$TARGET_DIR" ]] || die "Local destination already exists: $TARGET_DIR"
if gh repo view "$REPO_FULL_NAME" >/dev/null 2>&1; then
  die "GitHub repository already exists: $REPO_FULL_NAME"
fi

printf '\nConfiguration:\n'
printf '  Repository:   %s (private)\n' "$REPO_FULL_NAME"
printf '  Description:  %s\n' "$DESCRIPTION"
printf '  Dev hostname: %s\n' "$DEV_HOSTNAME"
printf '  Prod hostname: %s\n' "$PROD_HOSTNAME"
printf '  Dev target:   %s\n' "$DEV_TARGET"
printf '  Prod target:  %s\n' "$PROD_TARGET"
if [[ "$CLI_MODE" == false ]]; then
  read -r -p "Create repository and publish template? [Y/n]: " confirm
  [[ -z "$confirm" || "$confirm" =~ ^[Yy]([Ee][Ss])?$ ]] || die "Cancelled."
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

info "Cloning source template"
git clone --quiet --depth 1 --branch "$SOURCE_BRANCH" "$SOURCE_REPO" "$TMP_DIR/source"
[[ -d "$TMP_DIR/source/template" ]] || die "Source repository does not contain template/."
for template_file in .env.example config/project.yaml \
  docker-compose.yml docker-compose.dev.yml docker-compose.prod.yml; do
  [[ -f "$TMP_DIR/source/template/$template_file" ]] ||
    die "Template is missing $template_file."
done

info "Creating private repository"
gh repo create "$REPO_FULL_NAME" --private --description "$DESCRIPTION"

info "Cloning new repository"
git clone --quiet "https://github.com/${REPO_FULL_NAME}.git" "$TARGET_DIR"

info "Copying template contents"
cp -a "$TMP_DIR/source/template/." "$TARGET_DIR/"

ENV_EXAMPLE="${TARGET_DIR}/.env.example"
ENV_FILE="${TARGET_DIR}/.env"
YAML_FILE="${TARGET_DIR}/config/project.yaml"
for generated_file in .env.example config/project.yaml \
  docker-compose.yml docker-compose.dev.yml docker-compose.prod.yml; do
  [[ -f "$TARGET_DIR/$generated_file" ]] ||
    die "Copied template is missing $generated_file."
done

info "Generating .env from .env.example"
# Bash reads .env.example line by line, replacing known variables and preserving
# comments, blank lines, ordering, and variables added by future template versions.
# Parallel arrays (Bash 3.2 compatible)
ENV_KEYS=(
  REGISTRY
  HARBOR_PROJECT
  IMAGE_NAME
  IMAGE_TAG
  CONTAINER_NAME
  BIND_ADDRESS
  HOST_PORT
  CONTAINER_PORT
  APP_ENV
  APP_HOSTNAME
  APP_UPSTREAM
)
ENV_VALS=(
  "$REGISTRY"
  "$HARBOR_PROJECT"
  "$PROJECT_NAME"
  "$IMAGE_TAG"
  "$PROJECT_NAME"
  "$BIND_ADDRESS"
  "$HOST_PORT"
  "$CONTAINER_PORT"
  "development"
  "$DEV_HOSTNAME"
  "${BIND_ADDRESS}:${CONTAINER_PORT}"
)
# Track seen keys with parallel array
ENV_SEEN=()
for _ in "${ENV_KEYS[@]}"; do ENV_SEEN+=("0"); done
: > "$ENV_FILE"
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]]; then
    key="${BASH_REMATCH[1]}"
    # Linear search in parallel arrays (Bash 3.2 compatible)
    found_idx=-1
    for i in "${!ENV_KEYS[@]}"; do
      if [[ "${ENV_KEYS[i]}" == "$key" ]]; then
        found_idx=$i
        break
      fi
    done
    if [[ $found_idx -ge 0 ]]; then
      printf '%s=%s\n' "$key" "${ENV_VALS[found_idx]}" >> "$ENV_FILE"
      ENV_SEEN[found_idx]=1
    else
      printf '%s\n' "$line" >> "$ENV_FILE"
    fi
  else
    printf '%s\n' "$line" >> "$ENV_FILE"
  fi
done < "$ENV_EXAMPLE"

for i in "${!ENV_KEYS[@]}"; do
  [[ ${ENV_SEEN[i]} -eq 1 ]] ||
    die "Template .env.example is missing expected key: ${ENV_KEYS[i]}"
done
chmod 600 "$ENV_FILE"

info "Baking project values into the Docker Compose files"
# Matches must be unique template lines; bake fails loudly if the template
# drifts. Deployments keep working without .env for these values.
BASE_COMPOSE="${TARGET_DIR}/docker-compose.yml"
DEV_COMPOSE="${TARGET_DIR}/docker-compose.dev.yml"
PROD_COMPOSE="${TARGET_DIR}/docker-compose.prod.yml"
PORT_MAPPING="\"${BIND_ADDRESS}:${HOST_PORT}:${CONTAINER_PORT}\""

bake "$BASE_COMPOSE" 'image: "${REGISTRY' \
  "    image: ${REGISTRY}/${HARBOR_PROJECT}/${PROJECT_NAME}:${IMAGE_TAG}"
bake "$BASE_COMPOSE" 'container_name:' \
  "    container_name: ${PROJECT_NAME}"
bake "$BASE_COMPOSE" '"${BIND_ADDRESS' \
  "      - ${PORT_MAPPING}"
bake "$BASE_COMPOSE" 'caddy: http://' \
  "      caddy: http://${DEV_HOSTNAME}"
bake "$BASE_COMPOSE" 'caddy.reverse_proxy:' \
  "      caddy.reverse_proxy: \"{{upstreams ${CONTAINER_PORT}}}\""
bake "$DEV_COMPOSE" 'APP_ENV:' "      APP_ENV: development"
bake "$DEV_COMPOSE" '"${BIND_ADDRESS' "      - ${PORT_MAPPING}"
bake "$PROD_COMPOSE" 'APP_ENV:' "      APP_ENV: production"

if command -v docker >/dev/null 2>&1; then
  info "Validating Docker Compose files with docker compose"
  (cd "$TARGET_DIR" && docker compose config --quiet) ||
    die "docker compose rejected the generated docker-compose.yml."
  (cd "$TARGET_DIR" && docker compose -f docker-compose.yml -f docker-compose.dev.yml config --quiet) ||
    die "docker compose rejected the generated docker-compose.dev.yml."
  (cd "$TARGET_DIR" && docker compose -f docker-compose.yml -f docker-compose.prod.yml config --quiet) ||
    die "docker compose rejected the generated docker-compose.prod.yml."
fi

info "Updating config/project.yaml"
# yaml_quote emits double-quoted YAML scalars; embedded quotes escaped.
yaml_quote() {
  local value="$1"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}
bake "$YAML_FILE" 'name: "template"' \
  "  name: $(yaml_quote "$PROJECT_NAME")"
bake "$YAML_FILE" 'description: "repo template"' \
  "  description: $(yaml_quote "$DESCRIPTION")"
bake "$YAML_FILE" 'repository: "repo-template"' \
  "  repository: $(yaml_quote "$PROJECT_NAME")"
bake "$YAML_FILE" 'organization: "Facu-HomeLab"' \
  "  organization: $(yaml_quote "$ORG")"
bake "$YAML_FILE" 'registry: "reg.internal.facuynati.website"' \
  "  registry: $(yaml_quote "$REGISTRY")"
bake "$YAML_FILE" 'harbor_project: "applications"' \
  "  harbor_project: $(yaml_quote "$HARBOR_PROJECT")"
bake "$YAML_FILE" 'image: "template"' \
  "  image: $(yaml_quote "$PROJECT_NAME")"
bake "$YAML_FILE" "port: 3000" \
  "  port: ${CONTAINER_PORT}"
bake "$YAML_FILE" 'hostname: "template.dev.facuynati.website"' \
  "    hostname: $(yaml_quote "$DEV_HOSTNAME")"
bake "$YAML_FILE" 'hostname: "template.facuynati.website"' \
  "    hostname: $(yaml_quote "$PROD_HOSTNAME")"
bake "$YAML_FILE" 'target: "proxmox-dev"' \
  "    target: $(yaml_quote "$DEV_TARGET")"
bake "$YAML_FILE" 'target: "proxmox-prod"' \
  "    target: $(yaml_quote "$PROD_TARGET")"

git -C "$TARGET_DIR" check-ignore -q .env ||
  die ".env is not ignored by .gitignore; refusing to commit it."
# Basic .env syntax check using Bash only.
line_number=0
while IFS= read -r line || [[ -n "$line" ]]; do
  ((line_number += 1))
  [[ -z "${line//[[:space:]]/}" || "$line" =~ ^[[:space:]]*# ]] && continue
  [[ "$line" == *=* ]] || die "Invalid .env line ${line_number}: missing '='"
done < "$ENV_FILE"

info "Creating initial commit"
git -C "$TARGET_DIR" add -A
git -C "$TARGET_DIR" diff --cached --quiet && die "No changes to commit."
git -C "$TARGET_DIR" -c user.name="$(git config user.name || gh api user --jq .login)" \
  -c user.email="$(git config user.email || printf '%s@users.noreply.github.com' "$(gh api user --jq .id)")" \
  commit -m "chore: initialize project from template"
git -C "$TARGET_DIR" branch -M main
git -C "$TARGET_DIR" push -u origin main

info "Completed successfully"
printf 'Repository: https://github.com/%s\n' "$REPO_FULL_NAME"
printf 'Local path: %s\n' "$TARGET_DIR"
printf 'Generated:  %s/.env\n' "$TARGET_DIR"
printf 'Generated:  %s/config/project.yaml\n' "$TARGET_DIR"
printf 'Filled:     %s/docker-compose.yml (+ .dev.yml, .prod.yml)\n' "$TARGET_DIR"
