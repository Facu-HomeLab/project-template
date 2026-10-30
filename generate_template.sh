#!/usr/bin/env bash
#
# generate_template.sh
# Descarga Facu-HomeLab/project-template y ejecuta sus generadores.
#
# Uso:
#   curl -fsSL https://raw.githubusercontent.com/Facu-HomeLab/project-template/main/generate_template.sh | bash
#
set -Eeuo pipefail

REPO_OWNER="Facu-HomeLab"
REPO_NAME="project-template"
BRANCH="${TEMPLATE_BRANCH:-main}"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
ARCHIVE_URL="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${BRANCH}"

TARGET_DIR="${TEMPLATE_TARGET_DIR:-$PWD}"
WORK_DIR=""

log()  { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

cleanup() {
  if [[ -n "${WORK_DIR:-}" && -d "$WORK_DIR" ]]; then
    rm -rf "$WORK_DIR"
  fi
}
trap cleanup EXIT

for cmd in curl tar find bash; do
  command -v "$cmd" >/dev/null 2>&1 || die "No se encontró el comando requerido: $cmd"
done

[[ -d "$TARGET_DIR" ]] || die "El directorio destino no existe: $TARGET_DIR"
TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

if [[ -n "$(find "$TARGET_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
  die "El directorio destino no está vacío: $TARGET_DIR
Ejecutá el script desde una carpeta nueva o vacía para evitar sobrescribir archivos."
fi

WORK_DIR="$(mktemp -d -t project-template.XXXXXX)"
ARCHIVE="$WORK_DIR/repository.tar.gz"
REPO_DIR="$WORK_DIR/repository"

log "Repositorio: $REPO_URL"
log "Rama: $BRANCH"
log "Destino: $TARGET_DIR"

log "Descargando el repositorio..."
if ! curl --fail --silent --show-error --location "$ARCHIVE_URL" --output "$ARCHIVE"; then
  die "No se pudo descargar el repositorio. Verificá que exista la rama '$BRANCH' y que el repositorio sea accesible."
fi

mkdir -p "$REPO_DIR"
tar -xzf "$ARCHIVE" --strip-components=1 -C "$REPO_DIR" ||
  die "No se pudo extraer el archivo descargado."

GENERATORS=(
  "01-create-structure.sh"
  "02-create-config.sh"
  "03-create-files.sh"
  "04-create-workflows.sh"
)

log "Comprobando los generadores del repositorio..."
for generator in "${GENERATORS[@]}"; do
  generator_path="$REPO_DIR/scripts/$generator"
  [[ -f "$generator_path" ]] || die "Falta el archivo requerido: scripts/$generator
El repositorio todavía no contiene todos los generadores. Subí los scripts 01 a 04 a la carpeta scripts/ del repositorio y volvé a ejecutar este comando."
  [[ -r "$generator_path" ]] || die "No se puede leer: $generator_path"
done

log "Generando la estructura del proyecto..."
for generator in "${GENERATORS[@]}"; do
  generator_path="$REPO_DIR/scripts/$generator"
  log "Ejecutando $generator..."
  bash "$generator_path" "$TARGET_DIR"
done

log "Generación finalizada."
printf '\nProyecto generado en: %s\n' "$TARGET_DIR"
printf 'Repositorio fuente: %s (rama %s)\n' "$REPO_URL" "$BRANCH"
printf '\nPróximo paso: revisá config/project.yaml y los archivos generados antes de inicializar Git.\n'
