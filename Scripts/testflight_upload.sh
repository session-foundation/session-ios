#!/usr/bin/env bash
#
# testflight_upload.sh — upload an already-exported IPA to TestFlight / App Store
# Connect using the App Store Connect API key.
#
# Decoupled from build_release.sh so a maintainer can re-upload an existing build
# without re-archiving.
#
# Usage:
#   Scripts/testflight_upload.sh [version|ipa-path]
#
#   With no argument it uploads build/export/session-<MARKETING_VERSION>.ipa.
#   You may pass a version (e.g. 2.15.3) or a direct path to a .ipa.
#
# Credentials come from the environment — see Scripts/release_env.sh. Signing/keychain
# are not needed here, so SKIP_KEYCHAIN is forced on (only the API key is required).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_ROOT"

ARG="${1:-}"
if [ -n "$ARG" ] && [ -f "$ARG" ]; then
    IPA_PATH="$ARG"
else
    VERSION="$ARG"
    if [ -z "$VERSION" ]; then
        VERSION="$(xcodebuild -project Session.xcodeproj -scheme Session \
            -configuration App_Store_Release -showBuildSettings 2>/dev/null \
            | awk -F' = ' '/ MARKETING_VERSION / {print $2; exit}')"
    fi
    IPA_PATH="./build/export/session-${VERSION}.ipa"
fi

if [ ! -f "$IPA_PATH" ]; then
    echo "Error: IPA not found: ${IPA_PATH} (run Scripts/build_release.sh first)." >&2
    exit 1
fi

# Only the API key is needed for upload — skip the signing keychain entirely.
export SKIP_KEYCHAIN=1
# shellcheck source=Scripts/release_env.sh
source "$SCRIPT_DIR/release_env.sh"

echo "--- Uploading ${IPA_PATH} to TestFlight ---"
xcrun altool --upload-app \
    -f "$IPA_PATH" \
    --type ios \
    --apiKey "$ASC_KEY_ID" \
    --apiIssuer "$ASC_ISSUER_ID"

echo "--- Upload submitted. The build will appear in App Store Connect → TestFlight"
echo "    once Apple finishes processing it. ---"
