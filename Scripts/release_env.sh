#!/usr/bin/env bash
#
# release_env.sh — shared credential + keychain setup for the release scripts.
#
# This file is meant to be SOURCED, not executed:
#
#     source "$(dirname "$0")/release_env.sh"
#
# It validates the required environment variables, materialises the App Store
# Connect API key and (optionally) a distribution certificate into a temporary
# keychain, and installs a cleanup trap that removes all secrets when the calling
# script exits (success, failure, or interrupt).
#
# See RELEASING.md for how to obtain these credentials.
#
# Required environment variables:
#   ASC_KEY_ID              10-char App Store Connect API key ID
#   ASC_ISSUER_ID           App Store Connect issuer UUID
#   ASC_KEY_P8_BASE64       base64 of the .p8 private key
#     NOTE: for distribution/cloud signing the key needs the *Admin* role.
#
# Signing mode:
#   SKIP_KEYCHAIN=1         Cloud-managed signing (the normal path for this project): do not
#                           create a keychain or import a cert — xcodebuild cloud-signs via
#                           the API key + -allowProvisioningUpdates. Apple holds the private
#                           key. Also covers "a distribution identity already exists in the
#                           login keychain" for local runs.
#
# Fallback (only when NOT using cloud-managed signing — required unless SKIP_KEYCHAIN=1):
#   ASC_DIST_CERT_P12_BASE64   base64 of the Apple Distribution cert (incl. private key)
#   ASC_DIST_CERT_PASSWORD     the .p12 export password
#   KEYCHAIN_PASSWORD          (optional) password for the temp keychain (generated if unset)
#
# On success it exports:
#   ASC_KEY_PATH            absolute path to AuthKey_<ID>.p8 (for -authenticationKeyPath)

# --- guard against direct execution --------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    echo "release_env.sh must be sourced, not executed:  source ${BASH_SOURCE[0]}" >&2
    exit 1
fi

# NOTE: we deliberately do not enable `set -x` anywhere that could echo secrets.

# --- load .env (repo root) if present ------------------------------------------
_RELEASE_ENV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ENV_FILE="$_RELEASE_ENV_DIR/../.env"
if [ -f "$_ENV_FILE" ]; then
    echo "[release_env] Loading credentials from .env"
    set -a; # shellcheck disable=SC1090
    source "$_ENV_FILE"; set +a
fi

# --- validate required env vars ------------------------------------------------
: "${ASC_KEY_ID:?ASC_KEY_ID is required}"
: "${ASC_ISSUER_ID:?ASC_ISSUER_ID is required}"
: "${ASC_KEY_P8_BASE64:?ASC_KEY_P8_BASE64 is required}"

_RELEASE_ENV_CLEANUP=()
_release_env_cleanup() {
    local item
    for item in "${_RELEASE_ENV_CLEANUP[@]:-}"; do
        [ -z "$item" ] && continue
        case "$item" in
            keychain:*) security delete-keychain "${item#keychain:}" 2>/dev/null || true ;;
            *)          rm -f "$item" 2>/dev/null || true ;;
        esac
    done
}
trap _release_env_cleanup EXIT INT TERM

# --- materialise the App Store Connect API key ---------------------------------
# altool / iTMSTransporter locate the key by filename convention in one of a few
# dirs; ~/.appstoreconnect/private_keys is one of them, so we can use the same file
# for both `xcodebuild -authenticationKeyPath` and `altool --apiKey`.
_ASC_KEY_DIR="$HOME/.appstoreconnect/private_keys"
mkdir -p "$_ASC_KEY_DIR"
chmod 700 "$_ASC_KEY_DIR"
export ASC_KEY_PATH="$_ASC_KEY_DIR/AuthKey_${ASC_KEY_ID}.p8"
printf '%s' "$ASC_KEY_P8_BASE64" | base64 --decode > "$ASC_KEY_PATH"
chmod 600 "$ASC_KEY_PATH"
_RELEASE_ENV_CLEANUP+=("$ASC_KEY_PATH")
echo "[release_env] App Store Connect API key ready (key id: ${ASC_KEY_ID})."

# --- distribution certificate / keychain ---------------------------------------
if [ "${SKIP_KEYCHAIN:-0}" = "1" ]; then
    echo "[release_env] SKIP_KEYCHAIN=1 — cloud-managed signing (no local cert imported)."
else
    : "${ASC_DIST_CERT_P12_BASE64:?ASC_DIST_CERT_P12_BASE64 is required (or set SKIP_KEYCHAIN=1)}"
    : "${ASC_DIST_CERT_PASSWORD:?ASC_DIST_CERT_PASSWORD is required (or set SKIP_KEYCHAIN=1)}"

    KEYCHAIN_PASSWORD="${KEYCHAIN_PASSWORD:-$(openssl rand -base64 24)}"
    _KEYCHAIN_PATH="$HOME/Library/Keychains/session-release-$$.keychain-db"
    _P12_PATH="$(mktemp -t session-dist-cert).p12"
    _RELEASE_ENV_CLEANUP+=("keychain:$_KEYCHAIN_PATH" "$_P12_PATH")

    printf '%s' "$ASC_DIST_CERT_P12_BASE64" | base64 --decode > "$_P12_PATH"

    security create-keychain -p "$KEYCHAIN_PASSWORD" "$_KEYCHAIN_PATH"
    security set-keychain-settings -lut 3600 "$_KEYCHAIN_PATH"
    security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$_KEYCHAIN_PATH"
    security import "$_P12_PATH" -k "$_KEYCHAIN_PATH" -P "$ASC_DIST_CERT_PASSWORD" \
        -T /usr/bin/codesign -T /usr/bin/xcodebuild
    # Allow codesign/xcodebuild to use the key without an interactive prompt.
    security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$_KEYCHAIN_PATH" >/dev/null
    # Prepend our keychain to the user search list (preserving the existing entries).
    _EXISTING_KEYCHAINS="$(security list-keychains -d user | sed 's/[[:space:]]*"//;s/"[[:space:]]*$//')"
    # shellcheck disable=SC2086
    security list-keychains -d user -s "$_KEYCHAIN_PATH" $_EXISTING_KEYCHAINS
    rm -f "$_P12_PATH"

    echo "[release_env] Distribution certificate imported into temp keychain."
fi

echo "[release_env] Ready."
