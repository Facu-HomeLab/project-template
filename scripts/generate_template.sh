#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ORG="Facu-HomeLab"
SOURCE_REPO="https://github.com/${ORG}/project-template.git"
SOURCE_BRANCH="main"

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

Dependencies: bash, gh, git, and standard Unix utilities (including awk).
USAGE
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
info() { printf '\n==> %s\n' "$*"; }
need_command() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

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
declare -A SEEN=()

while (($#)); do
  case "$1" in
    --name|--description|--dev-hostname|--prod-hostname|--dev-target|--prod-target)
      (($# >= 2)) || die "$1 requires a value"
      key="$1"; value="$2"
      case "$key" in
        --name) PROJECT_NAME="$value" ;;
        --description) DESCRIPTION="$value" ;;
        --dev-hostname) DEV_HOSTNAME="$value" ;;
        --prod-hostname) PROD_HOSTNAME="$value" ;;
        --dev-target) DEV_TARGET="$value" ;;
        --prod-target) PROD_TARGET="$value" ;;
      esac
      SEEN["$key"]=1
      CLI_MODE=true
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1 (use --help)" ;;
  esac
done

need_command gh
need_command git
need_command awk
gh auth status >/dev/null 2>&1 || die "GitHub CLI is not authenticated. Run: gh auth login."
gh api "orgs/${ORG}" >/dev/null 2>&1 ||
  die "Cannot access organization ${ORG}; check membership and permissions."

if [[ "$CLI_MODE" == false ]]; then
  prompt_value PROJECT_NAME "Project name" "my-project"
  validate_project_name "$PROJECT_NAME"
  prompt_value DESCRIPTION "Project description" "$PROJECT_NAME"
  prompt_value DEV_HOSTNAME "Development hostname" "${PROJECT_NAME}.dev.facuynati.online"
  prompt_value PROD_HOSTNAME "Production hostname" "${PROJECT_NAME}.facuynati.online"
  prompt_value DEV_TARGET "Development deployment target" "proxmox-dev"
  prompt_value PROD_TARGET "Production deployment target" "proxmox-prod"
else
  for option in --name --description --dev-hostname --prod-hostname --dev-target --prod-target; do
    [[ -n "${SEEN[$option]:-}" ]] || die "CLI mode requires $option."
  done
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
[[ -f "$TMP_DIR/source/template/.env.example" ]] || die "Template is missing .env.example."
[[ -f "$TMP_DIR/source/template/config/project.yaml" ]] || die "Template is missing config/project.yaml."

info "Creating private repository"
gh repo create "$REPO_FULL_NAME" --private --description "$DESCRIPTION"

info "Cloning new repository"
git clone --quiet "https://github.com/${REPO_FULL_NAME}.git" "$TARGET_DIR"

info "Copying template contents"
cp -a "$TMP_DIR/source/template/." "$TARGET_DIR/"

ENV_EXAMPLE="${TARGET_DIR}/.env.example"
ENV_FILE="${TARGET_DIR}/.env"
YAML_FILE="${TARGET_DIR}/config/project.yaml"
[[ -f "$ENV_EXAMPLE" ]] || die "Copied template is missing .env.example."
[[ -f "$YAML_FILE" ]] || die "Copied template is missing config/project.yaml."

info "Generating .env from .env.example"
# Bash reads .env.example line by line, replacing known variables and preserving
# comments, blank lines, ordering, and variables added by future template versions.
declare -A ENV_VALUES=(
  [REGISTRY]="reg.internal.facuynati.website"
  [HARBOR_PROJECT]="applications"
  [IMAGE_NAME]="$PROJECT_NAME"
  [IMAGE_TAG]="latest"
  [CONTAINER_NAME]="$PROJECT_NAME"
  [BIND_ADDRESS]="127.0.0.1"
  [HOST_PORT]="3000"
  [CONTAINER_PORT]="80"
  [APP_ENV]="development"
  [APP_HOSTNAME]="$DEV_HOSTNAME"
  [APP_UPSTREAM]="127.0.0.1:80"
)
declare -A ENV_SEEN=()
: > "$ENV_FILE"
while IFS= read -r line || [[ -n "$line" ]]; do
  if [[ "$line" =~ ^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*= ]]; then
    key="${BASH_REMATCH[1]}"
    if [[ -v "ENV_VALUES[$key]" ]]; then
      printf '%s=%s\n' "$key" "${ENV_VALUES[$key]}" >> "$ENV_FILE"
      ENV_SEEN["$key"]=1
    else
      printf '%s\n' "$line" >> "$ENV_FILE"
    fi
  else
    printf '%s\n' "$line" >> "$ENV_FILE"
  fi
done < "$ENV_EXAMPLE"

for key in "${!ENV_VALUES[@]}"; do
  [[ -n "${ENV_SEEN[$key]:-}" ]] ||
    die "Template .env.example is missing expected key: $key"
done
chmod 600 "$ENV_FILE"

info "Updating config/project.yaml"
# YAML values are emitted as single-quoted scalars; embedded apostrophes double.
yaml_quote() {
  local value="$1"
  value="${value//\'/\'\'}"
  printf "'%s'" "$value"
}
export YAML_PROJECT_NAME="$(yaml_quote "$PROJECT_NAME")"
export YAML_PROJECT_DESCRIPTION="$(yaml_quote "$DESCRIPTION")"
export YAML_ORG="$(yaml_quote "$ORG")"
export YAML_REGISTRY="$(yaml_quote "reg.internal.facuynati.website")"
export YAML_HARBOR_PROJECT="$(yaml_quote "applications")"
export YAML_IMAGE="$(yaml_quote "$PROJECT_NAME")"
export YAML_CONTAINER_PORT="80"
export YAML_DEV_HOSTNAME="$(yaml_quote "$DEV_HOSTNAME")"
export YAML_PROD_HOSTNAME="$(yaml_quote "$PROD_HOSTNAME")"
export YAML_DEV_TARGET="$(yaml_quote "$DEV_TARGET")"
export YAML_PROD_TARGET="$(yaml_quote "$PROD_TARGET")"

YAML_TMP="${YAML_FILE}.tmp"
awk '
{
  if ($0 ~ /^[A-Za-z0-9_-]+:[[:space:]]*$/) {
    top = $0
    sub(/:.*/, "", top)
    subkey = ""
  } else if (top == "deployment" && $0 ~ /^  (dev|prod):[[:space:]]*$/) {
    subkey = $0
    sub(/^[[:space:]]*/, "", subkey)
    sub(/:.*/, "", subkey)
  }

  if (top == "project" && $0 ~ /^  name:[[:space:]]*/) {
    print "  name: " ENVIRON["YAML_PROJECT_NAME"]; found["project.name"]=1; next
  }
  if (top == "project" && $0 ~ /^  description:[[:space:]]*/) {
    print "  description: " ENVIRON["YAML_PROJECT_DESCRIPTION"]; found["project.description"]=1; next
  }
  if (top == "project" && $0 ~ /^  repository:[[:space:]]*/) {
    print "  repository: " ENVIRON["YAML_PROJECT_NAME"]; found["project.repository"]=1; next
  }
  if (top == "project" && $0 ~ /^  organization:[[:space:]]*/) {
    print "  organization: " ENVIRON["YAML_ORG"]; found["project.organization"]=1; next
  }
  if (top == "container" && $0 ~ /^  registry:[[:space:]]*/) {
    print "  registry: " ENVIRON["YAML_REGISTRY"]; found["container.registry"]=1; next
  }
  if (top == "container" && $0 ~ /^  harbor_project:[[:space:]]*/) {
    print "  harbor_project: " ENVIRON["YAML_HARBOR_PROJECT"]; found["container.harbor_project"]=1; next
  }
  if (top == "container" && $0 ~ /^  image:[[:space:]]*/) {
    print "  image: " ENVIRON["YAML_IMAGE"]; found["container.image"]=1; next
  }
  if (top == "container" && $0 ~ /^  port:[[:space:]]*/) {
    print "  port: " ENVIRON["YAML_CONTAINER_PORT"]; found["container.port"]=1; next
  }
  if (top == "deployment" && subkey == "dev" && $0 ~ /^    hostname:[[:space:]]*/) {
    print "    hostname: " ENVIRON["YAML_DEV_HOSTNAME"]; found["deployment.dev.hostname"]=1; next
  }
  if (top == "deployment" && subkey == "dev" && $0 ~ /^    target:[[:space:]]*/) {
    print "    target: " ENVIRON["YAML_DEV_TARGET"]; found["deployment.dev.target"]=1; next
  }
  if (top == "deployment" && subkey == "prod" && $0 ~ /^    hostname:[[:space:]]*/) {
    print "    hostname: " ENVIRON["YAML_PROD_HOSTNAME"]; found["deployment.prod.hostname"]=1; next
  }
  if (top == "deployment" && subkey == "prod" && $0 ~ /^    target:[[:space:]]*/) {
    print "    target: " ENVIRON["YAML_PROD_TARGET"]; found["deployment.prod.target"]=1; next
  }
  print
}
END {
  required[1]="project.name"
  required[2]="project.description"
  required[3]="project.repository"
  required[4]="project.organization"
  required[5]="container.registry"
  required[6]="container.harbor_project"
  required[7]="container.image"
  required[8]="container.port"
  required[9]="deployment.dev.hostname"
  required[10]="deployment.dev.target"
  required[11]="deployment.prod.hostname"
  required[12]="deployment.prod.target"
  for (i=1; i<=12; i++) {
    if (!found[required[i]]) {
      print "Missing expected YAML key: " required[i] > "/dev/stderr"
      failed=1
    }
  }
  if (failed) exit 2
}' "$YAML_FILE" > "$YAML_TMP" || {
  rm -f "$YAML_TMP"
  die "Could not update config/project.yaml; its structure differs from the expected template."
}
mv "$YAML_TMP" "$YAML_FILE"

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
printf 'Docker Compose and Dockerfile were not modified.\n'
