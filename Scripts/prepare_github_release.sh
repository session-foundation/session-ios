#!/usr/bin/env bash
#
# prepare_github_release.sh — create the GitHub tag + draft release for a version.
#
# Does NOT bump the version (that happens on dev via bump_version.sh and reaches master
# through review). This just tags the release branch's current head and opens a draft
# release. The version must already be committed on that branch.
#
# Usage:
#   Scripts/prepare_github_release.sh <version>
#
# Env:
#   RELEASE_REMOTE   git remote whose repo the release is created on (default: origin)
#   RELEASE_BRANCH   branch/ref to tag (default: master)
#
# Requires: gh. Aborts if a tag for <version> already exists.
set -euo pipefail

VERSION="${1:?Usage: prepare_github_release.sh <version>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

REMOTE="${RELEASE_REMOTE:-origin}"
BRANCH="${RELEASE_BRANCH:-master}"

# Guard: never clobber an existing tag/release.
if git rev-parse -q --verify "refs/tags/${VERSION}" >/dev/null 2>&1 \
   || git ls-remote --tags "$REMOTE" "refs/tags/${VERSION}" 2>/dev/null | grep -q .; then
    echo "Error: tag '${VERSION}' already exists. Aborting (bump the version first)." >&2
    exit 1
fi

echo "--- Creating draft release ${VERSION} (tagging ${BRANCH}) ---"
gh release create "$VERSION" \
    --draft \
    --target "$BRANCH" \
    --title "$VERSION" \
    --generate-notes

echo "--- Draft release ${VERSION} created. ---"
