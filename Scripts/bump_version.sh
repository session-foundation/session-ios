#!/usr/bin/env bash
#
# bump_version.sh — bump the app version on a dev branch and open a PR.
#
# Version changes belong on `dev` and reach `master` through the normal reviewed merge,
# so this does NOT touch master and is separate from the release flow. It bumps the
# project-level MARKETING_VERSION / CURRENT_PROJECT_VERSION (inherited by all targets),
# pushes a branch, and opens a PR into dev for review.
#
# Usage:
#   Scripts/bump_version.sh <version> [build]
#
#   version    new marketing version, e.g. 2.15.4
#   build      new build number (defaults to current + 1)
#
# Env:
#   RELEASE_REMOTE   git remote to branch from / push to (default: origin)
#   DEV_BRANCH       branch to base + target the PR on (default: dev)
#
# Requires: git, gh.
set -euo pipefail

NEW_VERSION="${1:?Usage: bump_version.sh <version> [build]}"
NEW_BUILD="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=Scripts/lib_version.sh
source "$SCRIPT_DIR/lib_version.sh"

PBX="Session.xcodeproj/project.pbxproj"
REMOTE="${RELEASE_REMOTE:-origin}"
DEV_BRANCH="${DEV_BRANCH:-dev}"
BR="bump/version-${NEW_VERSION}"

# --- branch off the latest dev -------------------------------------------------
git fetch "$REMOTE"
git checkout -B "$BR" "$REMOTE/$DEV_BRANCH"

# --- read current project-level values (from the tree we're editing) -----------
OLD_VERSION="$(read_project_version "$PBX" MARKETING_VERSION)"
OLD_BUILD="$(read_project_version "$PBX" CURRENT_PROJECT_VERSION)"
: "${OLD_VERSION:?could not read current MARKETING_VERSION from ${PBX}}"
: "${OLD_BUILD:?could not read current CURRENT_PROJECT_VERSION from ${PBX}}"
[ -n "$NEW_BUILD" ] || NEW_BUILD=$((OLD_BUILD + 1))

echo "--- Bumping version on ${BR} (off ${REMOTE}/${DEV_BRANCH}) ---"
echo "    marketing version: ${OLD_VERSION} -> ${NEW_VERSION}"
echo "    build number     : ${OLD_BUILD} -> ${NEW_BUILD}"

if [ "$OLD_VERSION" = "$NEW_VERSION" ] && [ "$OLD_BUILD" = "$NEW_BUILD" ]; then
    echo "Error: new version/build match the current values — nothing to bump." >&2
    exit 1
fi

# --- bump (old-value-anchored; the old values live only in the project-level configs) ---
mv_count=$(grep -c "MARKETING_VERSION = ${OLD_VERSION};" "$PBX" || true)
cpv_count=$(grep -c "CURRENT_PROJECT_VERSION = ${OLD_BUILD};" "$PBX" || true)
echo "    (updating ${mv_count} MARKETING_VERSION and ${cpv_count} CURRENT_PROJECT_VERSION lines)"
if [ "$mv_count" -eq 0 ] || [ "$cpv_count" -eq 0 ]; then
    echo "Error: could not find project-level version lines to bump. Aborting." >&2
    exit 1
fi

sed -i '' \
    -e "s/MARKETING_VERSION = ${OLD_VERSION};/MARKETING_VERSION = ${NEW_VERSION};/g" \
    -e "s/CURRENT_PROJECT_VERSION = ${OLD_BUILD};/CURRENT_PROJECT_VERSION = ${NEW_BUILD};/g" \
    "$PBX"

echo "--- Diff ---"
git --no-pager diff -- "$PBX" || true

# --- commit, push, open PR -----------------------------------------------------
git add "$PBX"
git commit -m "Bump version to ${NEW_VERSION} (build ${NEW_BUILD})"
git push -u "$REMOTE" "$BR"

echo "--- Opening PR into ${DEV_BRANCH} ---"
gh pr create \
    --base "$DEV_BRANCH" \
    --head "$BR" \
    --title "Bump version to ${NEW_VERSION} (build ${NEW_BUILD})" \
    --body "Bumps MARKETING_VERSION to ${NEW_VERSION} and CURRENT_PROJECT_VERSION to ${NEW_BUILD}."

echo "--- Done. Once merged into ${DEV_BRANCH} and released to master, run Scripts/release.sh ---"
