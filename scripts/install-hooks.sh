#!/usr/bin/env bash
# Points git at the repository's checked-in hooks, once per clone.
#
# Git never runs a checked-in hooks directory on its own: it only runs what is in the clone's own
# hooks directory, which is not version controlled. Setting core.hooksPath is what makes .githooks
# live, and it is per-clone configuration, so every clone has to run this. Nothing runs it
# automatically.
#
# The path is set relative, not absolute, so it resolves against whichever working tree git is
# running in. That is what makes the hooks work in a git worktree as well as the main clone, since
# the two share one config file.
set -euo pipefail

# Run with no arguments the script prints how to use it, then carries on.
if [ "$#" -eq 0 ]; then
    echo "Usage: bash scripts/install-hooks.sh"
    echo "  Sets core.hooksPath to .githooks for this clone, once."
    echo ""
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$REPO_DIR"

if [ ! -d .githooks ]; then
    echo "ERROR: no .githooks directory in $REPO_DIR. Run this from a checkout of the repository." >&2
    exit 1
fi

previous="$(git config --local --get core.hooksPath || true)"
if [ -n "$previous" ] && [ "$previous" != ".githooks" ]; then
    echo "Replacing the existing core.hooksPath ('$previous')."
fi

git config core.hooksPath .githooks

echo "Hooks installed: core.hooksPath = $(git config --get core.hooksPath)"
echo "  pre-commit: bash scripts/test-everything.sh"
