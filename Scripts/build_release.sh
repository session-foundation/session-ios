#!/usr/bin/env bash
#
# build_release.sh — archive a distribution device build, export a signed IPA, and
# (optionally) attach it to the GitHub draft release.
#
# Produces:
#   build/Session.xcarchive              the archive (incl. dSYMs/)
#   build/export/session-<version>.ipa   the signed, App-Store-ready IPA
#
# Usage:
#   Scripts/build_release.sh [version] [--attach]
#
#   version    marketing version, e.g. 2.15.3 (defaults to the project's MARKETING_VERSION)
#   --attach   upload the IPA to the GitHub draft release tagged <version> (needs `gh`)
#
# Credentials come from the environment — see Scripts/release_env.sh for the list.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

ATTACH=0
VERSION=""
for arg in "$@"; do
    case "$arg" in
        --attach) ATTACH=1 ;;
        *)        VERSION="$arg" ;;
    esac
done

# Fall back to the project's configured marketing version.
if [ -z "$VERSION" ]; then
    VERSION="$(xcodebuild -project Session.xcodeproj -scheme Session \
        -configuration App_Store_Release -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ MARKETING_VERSION / {print $2; exit}')"
fi
if [ -z "$VERSION" ]; then
    echo "Error: could not determine version (pass it explicitly)." >&2
    exit 1
fi
echo "--- Building release for version ${VERSION} ---"

# Set up credentials + signing (installs its own cleanup trap in this shell).
# shellcheck source=Scripts/release_env.sh
source "$SCRIPT_DIR/release_env.sh"

ARCHIVE_PATH="./build/Session.xcarchive"
EXPORT_DIR="./build/export"
IPA_PATH="${EXPORT_DIR}/session-${VERSION}.ipa"

mkdir -p ./build

# 1. Archive (distribution-signed device build; overrides live in build_ci.sh).
"$SCRIPT_DIR/build_ci.sh" archive-device \
    -archivePath "$ARCHIVE_PATH" \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"

# 2. Export the IPA.
rm -rf "$EXPORT_DIR"
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "./exportOptions.plist" \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" \
    -authenticationKeyID "$ASC_KEY_ID" \
    -authenticationKeyIssuerID "$ASC_ISSUER_ID"

# 3. Rename to the house convention (matches ~/Projects/Builds/session-<version>.ipa).
EXPORTED_IPA="$(find "$EXPORT_DIR" -maxdepth 1 -name '*.ipa' | head -n1)"
if [ -z "$EXPORTED_IPA" ]; then
    echo "Error: no .ipa found in ${EXPORT_DIR} after export." >&2
    exit 1
fi
if [ "$EXPORTED_IPA" != "$IPA_PATH" ]; then
    mv "$EXPORTED_IPA" "$IPA_PATH"
fi
echo "--- Exported ${IPA_PATH} ---"
echo "    dSYMs: ${ARCHIVE_PATH}/dSYMs/"

# 4. Optionally attach to the GitHub draft release.
if [ "$ATTACH" -eq 1 ]; then
    echo "--- Attaching IPA to GitHub release ${VERSION} ---"
    gh release upload "$VERSION" "$IPA_PATH" --clobber
fi

echo "--- Done. Upload to TestFlight with: Scripts/testflight_upload.sh ${VERSION} ---"
