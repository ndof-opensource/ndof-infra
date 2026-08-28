#!/usr/bin/env bash
# Instantiate a new ndof library repository from template/.
#
# usage: new-project.sh <name> <description> <dest-dir> [github-owner]
#   e.g. new-project.sh core "Core utilities for ndof" ../ndof-core my-org
#
# <name> is the short library name (lowercase, dash-separated). The script
# derives everything else: Conan package "ndof-<name>", CMake target
# "ndof::<name>", C++ namespace "ndof::<name-with-underscores>".
#
# Template token convention: tokens are __PROJECT_NAME__, __PROJECT_IDENT__,
# __PROJECT_DESCRIPTION__, __GITHUB_OWNER__ — nothing else. Adding a new token
# means updating three places in lockstep: the perl substitution below, the
# leftover-token grep in .github/workflows/test-infra.yml, and (if the token
# appears in a file or directory NAME) an explicit mv below — content
# substitution does not rename files; test-infra.yml checks names separately.
set -euo pipefail

if [[ $# -lt 3 ]]; then
    sed -n '2,7p' "$0" >&2
    exit 1
fi

export NP_NAME=$1
export NP_DESC=$2
DEST=$3
export NP_OWNER=${4:-ndof-opensource}
export NP_IDENT=${NP_NAME//-/_}

if [[ ! $NP_NAME =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "error: name must be lowercase, dash-separated: got '$NP_NAME'" >&2
    exit 1
fi
if [[ -e $DEST ]]; then
    echo "error: $DEST already exists" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cp -R "$ROOT/template" "$DEST"

# Tokens in file paths
mv "$DEST/include/ndof/__PROJECT_IDENT__" "$DEST/include/ndof/$NP_IDENT"

# Tokens in file contents
find "$DEST" -type f -print0 | xargs -0 perl -pi -e '
    s/__PROJECT_NAME__/$ENV{NP_NAME}/g;
    s/__PROJECT_IDENT__/$ENV{NP_IDENT}/g;
    s/__PROJECT_DESCRIPTION__/$ENV{NP_DESC}/g;
    s/__GITHUB_OWNER__/$ENV{NP_OWNER}/g;
'

git init -q "$DEST"
echo "created $DEST (git initialized; review and make the initial commit yourself)"
echo "remember to: choose a license, pin the dev image digest, pin the ci.yml workflow ref"
