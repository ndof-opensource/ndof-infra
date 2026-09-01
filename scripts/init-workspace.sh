#!/usr/bin/env bash
# Instantiate the ndof cross-repo workspace into a parent directory.
#
# usage: scripts/init-workspace.sh [parent-dir]
#
# Copies workspace/devcontainer.json and workspace/ndof.code-workspace from
# this repository into parent-dir, which should be a dedicated directory
# (conventionally named ndof-base) containing ONLY ndof repositories cloned
# side by side. parent-dir defaults to the directory containing this
# ndof-infra checkout, which under that convention is ndof-base itself.
# Rerun after an image adoption to refresh the pinned digest.
# See docs/releasing.md, "Live cross-repo development".
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST=${1:-"$ROOT/.."}
[[ -d $DEST ]] || { echo "error: $DEST is not a directory" >&2; exit 1; }
DEST="$(cd "$DEST" && pwd)"

cat >&2 <<WARN
This will write two files OUTSIDE any ndof repository:

    $DEST/.devcontainer/devcontainer.json
    $DEST/ndof.code-workspace

They exist for cross-repo development: opening $DEST (or its
ndof.code-workspace) in a devcontainer bind-mounts that ENTIRE directory
into the container. Keep only ndof repositories in it; anything else
placed there becomes visible to the workspace container too.

WARN
read -r -p "Type 'yes' to continue: " answer
if [[ ${answer} != yes ]]; then
    echo "aborted; nothing was written" >&2
    exit 1
fi

mkdir -p "$DEST/.devcontainer"
cp "$ROOT/workspace/devcontainer.json" "$DEST/.devcontainer/devcontainer.json"
cp "$ROOT/workspace/ndof.code-workspace" "$DEST/ndof.code-workspace"
echo "workspace instantiated in $DEST"
echo "next: open $DEST/ndof.code-workspace in your editor and reopen in container"
