#!/bin/sh
# Install local git hooks for this repo (run from repository root).
set -e
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="$ROOT/.git/hooks"

mkdir -p "$HOOKS_DIR"
cp "$ROOT/scripts/git-hooks/prepare-commit-msg" "$HOOKS_DIR/prepare-commit-msg"
cp "$ROOT/scripts/git-hooks/commit-msg" "$HOOKS_DIR/commit-msg"
chmod +x "$HOOKS_DIR/prepare-commit-msg" "$HOOKS_DIR/commit-msg"
echo "Installed git hooks (removes Co-authored-by: Cursor on prepare-commit-msg and commit-msg)."
