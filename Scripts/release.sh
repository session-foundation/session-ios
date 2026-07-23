#!/usr/bin/env bash
#
# release.sh — one-command release from master to TestFlight.
#
# Reads the version already committed on master (version bumps happen on dev via
# bump_version.sh and reach master through review — this script never changes the
# version). It then tags the release, builds + signs + exports the IPA, attaches it to a
# GitHub draft release, and uploads to TestFlight.
#
# Tag gating:
#   • If no tag exists for master's current version, it creates the tag + draft release
#     and proceeds.
#   • If a tag for that version already exists, a version bump probably still needs to be
#     merged — it pauses and lets you re-check after merging, build with the current
#     version anyway, or abort.
#
# Usage:
#   Scripts/release.sh [version] [options]
#
#   version                     optional sanity check against master's version
#
# Options:
#   -y, --yes                   don't pause for confirmations (non-interactive / CI)
#   --allow-existing-version    build/submit even if a tag for the version already exists
#   --skip-upload               stop after building + attaching (no TestFlight upload)
#   --skip-draft                don't create a GitHub tag/draft release
#   -h, --help                  show this help
#
# Env:
#   RELEASE_REMOTE  git remote to release from (default: origin)
#   RELEASE_BRANCH  branch to release (default: master)
#   Credentials     ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8_BASE64, SKIP_KEYCHAIN=1
#                   (loaded from .env if present; see RELEASING.md)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"
# shellcheck source=Scripts/lib_version.sh
source "$SCRIPT_DIR/lib_version.sh"

PBX="Session.xcodeproj/project.pbxproj"
REMOTE="${RELEASE_REMOTE:-origin}"
BRANCH="${RELEASE_BRANCH:-master}"
ENV_FILE="$REPO_ROOT/.env"

ASSUME_YES=0; SKIP_UPLOAD=0; SKIP_DRAFT=0; ALLOW_EXISTING=0; USER_VERSION=""
usage() { sed -n '2,38p' "$SCRIPT_DIR/release.sh" | sed 's/^# \{0,1\}//'; }
for arg in "$@"; do
    case "$arg" in
        -y|--yes)                 ASSUME_YES=1 ;;
        --allow-existing-version) ALLOW_EXISTING=1 ;;
        --skip-upload)            SKIP_UPLOAD=1 ;;
        --skip-draft)             SKIP_DRAFT=1 ;;
        -h|--help)                usage; exit 0 ;;
        -*)                       echo "Unknown option: $arg" >&2; exit 1 ;;
        *)                        USER_VERSION="$arg" ;;
    esac
done

# --- helpers -------------------------------------------------------------------
is_tty() { [ -t 0 ] && [ -t 1 ]; }
confirm() {
    [ "$ASSUME_YES" -eq 1 ] && return 0
    if ! is_tty; then
        echo "Refusing to continue without confirmation (not a TTY). Re-run with --yes." >&2
        return 1
    fi
    local reply; read -r -p "$1 [y/N] " reply; [[ "$reply" =~ ^[Yy]$ ]]
}
tag_exists() {
    git rev-parse -q --verify "refs/tags/$1" >/dev/null 2>&1 && return 0
    git ls-remote --tags "$REMOTE" "refs/tags/$1" 2>/dev/null | grep -q . && return 0
    return 1
}

# --- load .env + resolve credentials -------------------------------------------
if [ -f "$ENV_FILE" ]; then
    echo "--- Loading credentials from .env ---"
    set -a; # shellcheck disable=SC1090
    source "$ENV_FILE"; set +a
fi
NEWLY_PROMPTED=0
prompt_var() {
    local var="$1" text="$2" val
    [ -n "${!var:-}" ] && return 0
    if ! is_tty; then echo "Error: $var is not set (no .env value and no TTY to prompt)." >&2; exit 1; fi
    read -r -p "$text: " val
    export "$var=$val"; NEWLY_PROMPTED=1
}
# Update-or-insert KEY="value" in .env, preserving every other line (so a dev's other
# env vars aren't lost). Creates .env if absent.
upsert_env() {
    local key="$1" val="$2" tmp
    tmp="$(mktemp)"
    if [ -f "$ENV_FILE" ]; then grep -v "^${key}=" "$ENV_FILE" > "$tmp" 2>/dev/null || true; fi
    printf '%s="%s"\n' "$key" "$val" >> "$tmp"
    mv "$tmp" "$ENV_FILE"; chmod 600 "$ENV_FILE"
}

# Resolve each required credential; prompt for any that .env didn't provide.
if [ -z "${ASC_KEY_P8_BASE64:-}" ]; then
    if is_tty; then
        read -r -p "Path to App Store Connect API key (.p8): " _p8
        _p8="${_p8/#\~/$HOME}"
        [ -f "$_p8" ] || { echo "Error: file not found: $_p8" >&2; exit 1; }
        ASC_KEY_P8_BASE64="$(base64 -i "$_p8")"; export ASC_KEY_P8_BASE64; NEWLY_PROMPTED=1
    else
        echo "Error: ASC_KEY_P8_BASE64 is not set (no .env value and no TTY to prompt)." >&2; exit 1
    fi
fi
prompt_var ASC_KEY_ID    "App Store Connect API Key ID"
prompt_var ASC_ISSUER_ID "App Store Connect Issuer ID"
if [ -z "${SKIP_KEYCHAIN:-}" ] && [ -z "${ASC_DIST_CERT_P12_BASE64:-}" ]; then
    export SKIP_KEYCHAIN=1
fi

# Offer to persist anything newly entered, merging into any existing .env.
if [ "$NEWLY_PROMPTED" -eq 1 ] && is_tty; then
    if confirm "Save the entered credential(s) to .env for next time? (git-ignored; existing entries preserved)"; then
        umask 077
        upsert_env ASC_KEY_ID        "$ASC_KEY_ID"
        upsert_env ASC_ISSUER_ID     "$ASC_ISSUER_ID"
        upsert_env ASC_KEY_P8_BASE64 "$ASC_KEY_P8_BASE64"
        [ "${SKIP_KEYCHAIN:-}" = "1" ] && upsert_env SKIP_KEYCHAIN 1
        echo "Updated $ENV_FILE."
    fi
fi

# --- confirm the ref we're releasing -------------------------------------------
CUR_BRANCH="$(git branch --show-current 2>/dev/null || echo '')"
if [ "$CUR_BRANCH" != "$BRANCH" ]; then
    confirm "You are on '$CUR_BRANCH', not the release branch '$BRANCH'. Release from '$CUR_BRANCH' anyway?" \
        || { echo "Aborted. Check out $BRANCH first."; exit 1; }
fi
git fetch "$REMOTE" --tags >/dev/null 2>&1 || true

# --- read the version already on the branch (never modified here) --------------
VERSION="$(read_project_version "$PBX" MARKETING_VERSION)"
: "${VERSION:?could not read MARKETING_VERSION from ${PBX}}"
if [ -n "$USER_VERSION" ] && [ "$USER_VERSION" != "$VERSION" ]; then
    confirm "Version on ${CUR_BRANCH:-HEAD} is ${VERSION}, but you passed ${USER_VERSION}. Proceed with ${VERSION}?" \
        || { echo "Aborted."; exit 1; }
fi

# --- tag gating ----------------------------------------------------------------
REUSE_TAG=0
while tag_exists "$VERSION"; do
    echo ""
    echo "A release tag '${VERSION}' already exists."
    echo "This usually means the version on '${BRANCH}' hasn't been bumped since the last"
    echo "release — a bump needs to be merged (Scripts/bump_version.sh opens that PR)."
    if [ "$ALLOW_EXISTING" -eq 1 ]; then
        echo "(--allow-existing-version) Building the current version anyway."
        REUSE_TAG=1; break
    fi
    if [ "$ASSUME_YES" -eq 1 ] || ! is_tty; then
        echo "Refusing to proceed. Re-run with --allow-existing-version to build the current" >&2
        echo "version anyway, or merge a version bump first." >&2
        exit 1
    fi
    echo "  1) I've merged the bump — re-check '${BRANCH}'"
    echo "  2) Build & submit with the current version anyway (reuse existing tag)"
    echo "  3) Abort"
    read -r -p "Choose [1/2/3]: " choice
    case "$choice" in
        1|"") git fetch "$REMOTE" --tags >/dev/null 2>&1 || true
              [ "$CUR_BRANCH" = "$BRANCH" ] && git merge --ff-only "$REMOTE/$BRANCH" >/dev/null 2>&1 || true
              VERSION="$(read_project_version "$PBX" MARKETING_VERSION)"
              : "${VERSION:?could not re-read MARKETING_VERSION}"
              echo "Re-read version: ${VERSION}" ;;
        2)    REUSE_TAG=1; break ;;
        *)    echo "Aborted."; exit 1 ;;
    esac
done

# --- plan summary --------------------------------------------------------------
ORIGIN_URL="$(git remote get-url "$REMOTE" 2>/dev/null || echo '?')"
if [ "${SKIP_KEYCHAIN:-0}" = "1" ]; then SIGNING_DESC="cloud-managed"; else SIGNING_DESC="manual .p12"; fi
if [ "$REUSE_TAG" -eq 1 ]; then TAG_DESC="reuse existing tag ${VERSION}";
elif [ "$SKIP_DRAFT" -eq 1 ]; then TAG_DESC="(skip draft/tag)";
else TAG_DESC="create tag + draft ${VERSION}"; fi
STEP_UPLOAD="testflight"; [ "$SKIP_UPLOAD" -eq 1 ] && STEP_UPLOAD="(skip upload)"
echo ""
echo "=================== Release plan ==================="
echo "  Version   : $VERSION  (read from ${CUR_BRANCH:-HEAD})"
echo "  Remote    : $REMOTE  ($ORIGIN_URL)"
echo "  Tag/draft : $TAG_DESC"
echo "  Steps     : build+attach -> $STEP_UPLOAD"
echo "===================================================="
confirm "Proceed?" || { echo "Aborted."; exit 1; }

# --- 1. tag + draft release ----------------------------------------------------
if [ "$REUSE_TAG" -eq 0 ] && [ "$SKIP_DRAFT" -eq 0 ]; then
    if confirm "Create tag + draft release ${VERSION} on ${BRANCH}?"; then
        RELEASE_REMOTE="$REMOTE" RELEASE_BRANCH="$BRANCH" "$SCRIPT_DIR/prepare_github_release.sh" "$VERSION"
    else
        echo "Skipped draft creation."
    fi
fi

# --- 2. build + attach ---------------------------------------------------------
echo "--- Building + exporting + attaching IPA ---"
"$SCRIPT_DIR/build_release.sh" "$VERSION" --attach

# --- 3. upload to TestFlight ---------------------------------------------------
if [ "$SKIP_UPLOAD" -eq 0 ]; then
    if confirm "Upload session-${VERSION}.ipa to TestFlight?"; then
        "$SCRIPT_DIR/testflight_upload.sh" "$VERSION"
    else
        echo "Skipped TestFlight upload."
    fi
fi

# --- next steps ----------------------------------------------------------------
RELEASES_URL="$(printf '%s' "$ORIGIN_URL" | sed -E 's#git@github.com:#https://github.com/#; s#\.git$##')/releases"
echo ""
echo "=================== Done ==================="
echo "Remaining manual steps:"
echo "  • Publish the GitHub release when ready:  gh release edit ${VERSION} --draft=false"
echo "  • App Store Connect → TestFlight: manage testers / submit for review."
echo "  GitHub releases : $RELEASES_URL"
echo "  App Store Connect: https://appstoreconnect.apple.com/apps"
if is_tty && confirm "Open both in the browser now?"; then
    open "$RELEASES_URL" "https://appstoreconnect.apple.com/apps" 2>/dev/null || true
fi
