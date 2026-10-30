#!/usr/bin/env bash
#
# generate_template.sh
#
# Creates a new repository in the Facu-HomeLab GitHub organization,
# populates it from Facu-HomeLab/project-template, configures it,
# and pushes the initial project structure.
#
# Requirements:
#   - bash, curl, tar, git, gh
#   - gh authenticated with permission to create repositories in Facu-HomeLab
#
set -Eeuo pipefail

ORG="Facu-HomeLab"
TEMPLATE_REPO="https://github.com/${ORG}/project-template"
TEMPLATE_BRANCH="${TEMPLATE_BRANCH:-main}"
ARCHIVE_URL="https://codeload.github.com/${ORG}/project-template/tar.gz/refs/heads/${TEMPLATE_BRANCH}"

log()  { printf '\n\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

ask() {
  local prompt="$1" default="${2:-}" answer
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " answer </dev/tty
    printf '%s' "${answer:-$default}"
  else
    read -r -p "$prompt: " answer </dev/tty
    printf '%s' "$answer"
  fi
}

slugify() {
  printf '%s' "$1" |
    tr '[:upper:]' '[:lower:]' |
    sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//'
}

yaml_quote() {
  local value="${1//\'/\'\'}"
  printf "'%s'" "$value"
}

cleanup() {
  [[ -n "${WORK_DIR:-}" && -d "${WORK_DIR:-}" ]] && rm -rf "$WORK_DIR"
}
trap cleanup EXIT

for cmd in bash curl tar git gh sed tr find; do
  command -v "$cmd" >/dev/null 2>&1 || die "Falta el comando requerido: $cmd"
done

[[ -t 0 || -r /dev/tty ]] || die "Este script necesita un terminal interactivo."

gh auth status >/dev/null 2>&1 ||
  die "GitHub CLI no está autenticado. Ejecutá primero: gh auth login"

log "Configuración del nuevo proyecto"

PROJECT_NAME="$(ask 'Nombre del proyecto (ej. my-api)')"
[[ -n "$PROJECT_NAME" ]] || die "El nombre del proyecto es obligatorio."

REPO_NAME="$(slugify "$PROJECT_NAME")"
[[ "$REPO_NAME" =~ ^[a-z0-9]+([.-][a-z0-9]+)*$ ]] ||
  die "El nombre del repositorio no es válido: $REPO_NAME"

DESCRIPTION="$(ask 'Descripción breve' "Application generated from Facu-HomeLab project-template")"
VISIBILITY="$(ask 'Visibilidad del repositorio (private/public)' 'private')"
[[ "$VISIBILITY" == "private" || "$VISIBILITY" == "public" ]] ||
  die "La visibilidad debe ser private o public."

REGISTRY="$(ask 'Harbor registry' 'reg.internal.facuynati.website')"
HARBOR_PROJECT="$(ask 'Harbor project' 'applications')"
CONTAINER_PORT="$(ask 'Puerto interno del contenedor' '80')"
HOST_PORT="$(ask 'Puerto local publicado en el host' '3000')"
BASE_DOMAIN="$(ask 'Dominio base' 'facuynati.online')"
DEV_HOSTNAME="$(ask 'Hostname DEV' "${REPO_NAME}.dev.${BASE_DOMAIN}")"
PROD_HOSTNAME="$(ask 'Hostname PROD' "${REPO_NAME}.${BASE_DOMAIN}")"
DEV_TARGET="$(ask 'Target DEV' 'proxmox-dev')"
PROD_TARGET="$(ask 'Target PROD' 'proxmox-prod')"
HEALTHCHECK_PATH="$(ask 'Healthcheck path' '/health')"

[[ "$CONTAINER_PORT" =~ ^[0-9]+$ ]] && (( CONTAINER_PORT >= 1 && CONTAINER_PORT <= 65535 )) ||
  die "Puerto interno inválido."
[[ "$HOST_PORT" =~ ^[0-9]+$ ]] && (( HOST_PORT >= 1 && HOST_PORT <= 65535 )) ||
  die "Puerto del host inválido."
[[ "$REGISTRY" =~ ^[A-Za-z0-9.-]+(:[0-9]+)?$ ]] || die "Registry inválido."
[[ "$HARBOR_PROJECT" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || die "Harbor project inválido."
[[ "$BASE_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "Dominio base inválido."

PROJECT_DIR="$PWD"
[[ -z "$(find "$PROJECT_DIR" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" ]] ||
  die "La carpeta actual no está vacía. Ejecutá el script desde una carpeta nueva y vacía."

FULL_REPO="${ORG}/${REPO_NAME}"
if gh repo view "$FULL_REPO" >/dev/null 2>&1; then
  die "El repositorio ${FULL_REPO} ya existe. Elegí otro nombre o revisá GitHub."
fi

WORK_DIR="$(mktemp -d -t facu-project-template.XXXXXX)"
ARCHIVE="$WORK_DIR/template.tar.gz"
SOURCE_DIR="$WORK_DIR/source"

log "Descargando ${TEMPLATE_REPO} (rama ${TEMPLATE_BRANCH})..."
curl --fail --silent --show-error --location "$ARCHIVE_URL" --output "$ARCHIVE" ||
  die "No se pudo descargar el repositorio template."
mkdir -p "$SOURCE_DIR"
tar -xzf "$ARCHIVE" --strip-components=1 -C "$SOURCE_DIR" ||
  die "No se pudo extraer el repositorio template."

# Copiamos solamente los archivos solicitados. README y .env se generan
# específicamente para el nuevo proyecto; project.yaml se configura abajo.
FILES=(
  ".dockerignore"
  ".gitattributes"
  ".gitignore"
  "Dockerfile"
  "docker-compose.yml"
  "docker-compose.dev.yml"
  "docker-compose.prod.yml"
  ".github/PULL_REQUEST_TEMPLATE.md"
  ".github/workflows/ci.yml"
  ".github/workflows/deploy.yml"
  ".github/workflows/runner-test.yml"
  "src/.gitkeep"
)
for relative_path in "${FILES[@]}"; do
  [[ -f "$SOURCE_DIR/$relative_path" ]] ||
    die "El template no contiene el archivo esperado: $relative_path"
  mkdir -p "$PROJECT_DIR/$(dirname "$relative_path")"
  cp "$SOURCE_DIR/$relative_path" "$PROJECT_DIR/$relative_path"
done

mkdir -p config

# Configuración central del proyecto.
cat > config/project.yaml <<EOF
# Generated by generate_template.sh
project:
  name: $(yaml_quote "$PROJECT_NAME")
  description: $(yaml_quote "$DESCRIPTION")
  repository: $(yaml_quote "$REPO_NAME")
  organization: $(yaml_quote "$ORG")

container:
  registry: $(yaml_quote "$REGISTRY")
  harbor_project: $(yaml_quote "$HARBOR_PROJECT")
  image: $(yaml_quote "$REPO_NAME")
  port: ${CONTAINER_PORT}

deployment:
  provider: docker-compose
  dev:
    enabled: true
    hostname: $(yaml_quote "$DEV_HOSTNAME")
    environment: development
    target: $(yaml_quote "$DEV_TARGET")
  prod:
    enabled: true
    hostname: $(yaml_quote "$PROD_HOSTNAME")
    environment: production
    target: $(yaml_quote "$PROD_TARGET")

healthcheck:
  path: $(yaml_quote "$HEALTHCHECK_PATH")
  interval: 30
EOF

# Environment local. IMAGE is also understood by the central deployment
# workflow, which exports IMAGE with the release tag on the remote host.
cat > .env <<EOF
# Generated for ${FULL_REPO}
# Do not commit secrets to this file.

REGISTRY=${REGISTRY}
HARBOR_PROJECT=${HARBOR_PROJECT}
IMAGE_NAME=${REPO_NAME}
IMAGE_TAG=latest
IMAGE=${REGISTRY}/${HARBOR_PROJECT}/${REPO_NAME}:latest
CONTAINER_NAME=${REPO_NAME}

BIND_ADDRESS=127.0.0.1
HOST_PORT=${HOST_PORT}
CONTAINER_PORT=${CONTAINER_PORT}

APP_ENV=development
APP_HOSTNAME=${DEV_HOSTNAME}
APP_UPSTREAM=app:${CONTAINER_PORT}
EOF

# Keep a matching example file, but without project-specific secret values.
cp .env .env.example
sed -i 's/^# Generated for .*/# Copy this file to .env and adjust the values./' .env.example

# The template Compose file previously had a fixed demo hostname and port.
# Make it use the generated environment variables instead.
cat > docker-compose.yml <<'EOF'
services:
  app:
    image: "${IMAGE:?Set IMAGE in .env or deployment environment}"
    container_name: "${CONTAINER_NAME:-application}"
    restart: unless-stopped
    init: true
    stop_grace_period: 30s
    ports:
      - "${BIND_ADDRESS:-127.0.0.1}:${HOST_PORT:-3000}:${CONTAINER_PORT:-80}"
    environment:
      APP_ENV: "${APP_ENV:-production}"
    networks:
      - proxy_net
    labels:
      caddy: "${APP_HOSTNAME}"
      caddy.reverse_proxy: "{{upstreams ${CONTAINER_PORT:-80}}}"

networks:
  proxy_net:
    external: true
EOF

# The template workflow's compose path was deploy/docker-compose.yml,
# while this generated layout places Compose files in the repository root.
sed -i 's#compose_file: deploy/docker-compose.yml#compose_file: docker-compose.yml#' .github/workflows/deploy.yml

# Generic project README, customized with project metadata.
cat > README.md <<EOF
# ${PROJECT_NAME}

${DESCRIPTION}

This repository was generated from [Facu-HomeLab/project-template](${TEMPLATE_REPO}).

## Project configuration

| Setting | Value |
|---|---|
| GitHub repository | [${FULL_REPO}](https://github.com/${FULL_REPO}) |
| Container registry | \`${REGISTRY}\` |
| Harbor project | \`${HARBOR_PROJECT}\` |
| Image | \`${REPO_NAME}\` |
| Container port | \`${CONTAINER_PORT}\` |
| Host port | \`${HOST_PORT}\` |
| DEV hostname | \`${DEV_HOSTNAME}\` |
| PROD hostname | \`${PROD_HOSTNAME}\` |

## Repository layout

- \`src/\`: application source code
- \`config/project.yaml\`: project and deployment configuration
- \`docker-compose.yml\`: base container configuration
- \`docker-compose.dev.yml\`: development overrides
- \`docker-compose.prod.yml\`: production overrides
- \`.github/workflows/\`: CI, deployment and runner validation workflows

## Local setup

1. Review \`.env\` and \`config/project.yaml\`.
2. Add your application code under \`src/\`.
3. Adapt the \`Dockerfile\` to your application runtime and build process.
4. Ensure the application listens on container port \`${CONTAINER_PORT}\`.
5. Start the stack when the required external Docker network exists:

   \`\`\`bash
   docker compose --env-file .env -f docker-compose.yml -f docker-compose.dev.yml up -d --build
   \`\`\`

## Deployment

The deployment workflow calls the reusable workflow in \`Facu-HomeLab/.github\`.

Release tags:

- \`v1.2.3-dev.1\`: DEV
- \`v1.2.3-rc.1\`: STAGING
- \`v1.2.3\`: PROD

Check the central workflow's required OpenBao, Harbor, SSH and runner configuration before creating a release.

## Security

- \`.env\` is local configuration and must not contain committed secrets.
- GitHub deployment credentials are supplied through the configured OIDC/OpenBao flow.
- Review the generated configuration before deploying to production.
EOF

# Verify that .env is ignored.
if ! grep -qxF '.env' .gitignore; then
  printf '\n.env\n' >> .gitignore
fi

log "Archivos generados. Inicializando Git..."
git init -b main
git add .
git -c user.name="Facu-HomeLab Template Generator" \
    -c user.email="template-generator@users.noreply.github.com" \
    commit -m "Initial project generated from Facu-HomeLab template"

log "Creando el repositorio ${FULL_REPO} (${VISIBILITY}) y publicando main..."
gh repo create "$FULL_REPO" "--${VISIBILITY}" --source=. --remote=origin --push ||
  die "No se pudo crear/publicar el repositorio. Los archivos locales permanecen en $PROJECT_DIR."

ok "Proyecto generado y publicado."
printf '\nRepositorio: https://github.com/%s\n' "$FULL_REPO"
printf 'Directorio:  %s\n' "$PROJECT_DIR"
printf '\nRevisá especialmente Dockerfile, puertos, APP_HOSTNAME y config/project.yaml antes del primer deploy.\n'
