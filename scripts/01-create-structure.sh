
#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# Project Template - Structure Generator
# Version: 1.0.0
#
# Usage:
#   ./01-create-structure.sh
#   ./01-create-structure.sh /opt/github/project-template
#
# Default destination:
#   ./project-template
# ============================================================

SCRIPT_NAME="$(basename "$0")"
PROJECT_NAME="project-template"

# ------------------------------------------------------------
# Configuration
# ------------------------------------------------------------

if [[ $# -gt 1 ]]; then
    echo "Usage: $SCRIPT_NAME [destination]"
    exit 1
fi

if [[ $# -eq 1 ]]; then
    TARGET_DIR="$1"
else
    TARGET_DIR="./$PROJECT_NAME"
fi

# ------------------------------------------------------------
# Directory structure
# ------------------------------------------------------------

DIRECTORIES=(
    ".github/workflows"
    ".github/ISSUE_TEMPLATE"
    "config"
    "deploy"
    "scripts"
    "src"
    "tests"
)

# ------------------------------------------------------------
# Create project root
# ------------------------------------------------------------

echo
echo "=========================================="
echo " Project Template - Structure Generator"
echo "=========================================="
echo
echo "Destination: $TARGET_DIR"
echo

mkdir -p "$TARGET_DIR"

# ------------------------------------------------------------
# Create directories
# ------------------------------------------------------------

for directory in "${DIRECTORIES[@]}"; do
    mkdir -p "$TARGET_DIR/$directory"
    echo "[OK] Created: $directory"
done

# ------------------------------------------------------------
# Create directory placeholders
# ------------------------------------------------------------

touch "$TARGET_DIR/src/.gitkeep"
touch "$TARGET_DIR/tests/.gitkeep"

# ------------------------------------------------------------
# Display result
# ------------------------------------------------------------

echo
echo "=========================================="
echo " Structure generated successfully!"
echo "=========================================="
echo

if command -v tree >/dev/null 2>&1; then
    tree -a "$TARGET_DIR"
else
    find "$TARGET_DIR" -print | sort
fi

echo
echo "Next step:"
echo "  Execute 02-create-config.sh"
echo
