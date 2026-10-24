#!/usr/bin/env bash
#
# Install g by symlinking it into a directory on PATH.
#
# Usage: ./install.sh [DEST-DIR]     (default: ~/bin)

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./install.sh [DEST-DIR]

Symlinks the g script into DEST-DIR, which defaults to ~/bin. The directory is
created if it does not exist. If symlinking fails (for example on a filesystem
without symlink support) g is copied instead.

Environment:
  DESTDIR   Default destination directory; a positional argument wins.
EOF
}

case "${1-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="${SCRIPT_DIR}/g"

if [[ ! -f "$SRC" ]]; then
  echo "error: source script not found: ${SRC}" >&2
  exit 1
fi

DEST_DIR="${1:-${DESTDIR:-${HOME:?HOME is not set}/bin}}"
DEST="${DEST_DIR}/g"

if [[ ! -d "$DEST_DIR" ]]; then
  echo "Creating ${DEST_DIR}"
  mkdir -p "$DEST_DIR"
fi

# A symlink keeps the installed command in step with the working tree.
if ln -sfn "$SRC" "$DEST" 2>/dev/null; then
  echo "Linked: ${DEST} -> ${SRC}"
else
  install -m 755 "$SRC" "$DEST"
  echo "Copied: ${DEST}"
fi

if version_output="$("$DEST" version 2>/dev/null)"; then
  echo "Verified: ${version_output}"
else
  echo "error: installed command did not run: ${DEST}" >&2
  exit 1
fi

case ":${PATH}:" in
  *":${DEST_DIR}:"*) ;;
  *)
    echo
    echo "Warning: ${DEST_DIR} is not on PATH."
    echo "Add this line to ~/.zshrc (or ~/.bashrc):"
    echo
    echo "  export PATH=\"${DEST_DIR}:\$PATH\""
    ;;
esac
