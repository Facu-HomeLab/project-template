#!/usr/bin/env bash
#
# generate_template.sh
# Descarga Facu-HomeLab/project-template y ejecuta sus generadores.
#
# Uso recomendado:
#   curl -fsSLO https://raw.githubusercontent.com/Facu-HomeLab/project-template/main/generate_template.sh
#   bash generate_template.sh
#
set -Eeuo pipefail

REPO_OWNER="Facu-HomeLab"
REPO_NAME="project-template"
BRANCH="${TEMPLATE_BRANCH:-main}"
REPO_URL="https://github.com/${REPO_OWNER}/${REPO_NAME}"
ARCHIVE_URL="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/${BRANCH}"

TARGET_DIR="${TEMPLATE_TARGET_DIR:-$PWD}"
WORK_DIR=""

log() { printf '\n[INFO] %s\n' "$*"; }
die() { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }

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
Ejecutá el script desde una carpeta nueva o vacía."
fi

WORK_DIR="$(mktemp -d -t project-template.XXXXXX)"
ARCHIVE="$WORK_DIR/repository.tar.gz"
REPO_DIR="$WORK_DIR/repository"

log "Repositorio: $REPO_URL"
log "Rama: $BRANCH"
log "Destino: $TARGET_DIR"

log "Descargando repositorio..."
curl --fail --silent --show-error --location "$ARCHIVE_URL" --output "$ARCHIVE" ||
  die "No se pudo descargar el repositorio. Verificá la rama '$BRANCH'."

mkdir -p "$REPO_DIR"
tar -xzf "$ARCHIVE" --strip-components=1 -C "$REPO_DIR" ||
  die "No se pudo extraer el repositorio."

GENERATORS=(
  "01-create-structure.sh"
  "02-create-config.sh"
  "03-create-files.sh"
  "04-create-workflows.sh"
)

log "Verificando generadores..."
for generator in "${GENERATORS[@]}"; do
  generator_path="$REPO_DIR/scripts/$generator"
  [[ -f "$generator_path" ]] || die "Falta scripts/$generator. El repositorio debe contener todos los generadores."
  [[ -r "$generator_path" ]] || die "No se puede leer scripts/$generator."
done

log "Generando el template..."
for generator in "${GENERATORS[@]}"; do
  generator_path="$REPO_DIR/scripts/$generator"
  log "Ejecutando $generator..."

  # Mantiene disponible el terminal para las preguntas interactivas
  # aunque este script se haya descargado o invocado desde otro proceso.
  if [[ -r /dev/tty ]]; then
    bash "$generator_path" "$TARGET_DIR" </dev/tty
  else
    bash "$generator_path" "$TARGET_DIR"
  fi
done

log "Template generado correctamente."
printf '\nDestino: %s\n' "$TARGET_DIR"
printf 'Fuente: %s (rama %s)\n' "$REPO_URL" "$BRANCH"
printf '\nRevisá config/project.yaml y los archivos antes de inicializar Git.\n'
