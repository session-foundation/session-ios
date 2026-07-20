# Releasing Session iOS

A small suite of scripts under `Scripts/` builds a distribution IPA and submits it to
TestFlight without opening Xcode. They run locally (a maintainer just runs them) and are
CI-ready (all credentials come from environment variables). No Fastlane.

## Prerequisites

- Xcode + command-line tools, `xcbeautify`, and the GitHub CLI (`gh`, authenticated).
- An **App Store Connect API key** (`.p8`) — see below. For cloud signing it must be an
  **Admin Team Key** (an Individual key, or an App Manager key, will not work).

Signing uses **cloud-managed certificates** (the default when a team sets signing up through
Xcode — Apple holds the distribution private key). With the Admin API key and
`-allowProvisioningUpdates`, `xcodebuild` cloud-signs the distribution build without any
local certificate. **You do not need to create or export a `.p12`.** Providing one is only a
fallback for teams not using cloud-managed signing (see the last section).

## Obtaining credentials

### App Store Connect API key
Create it in App Store Connect → **Users and Access → Integrations**. Two requirements,
both confirmed necessary in practice for the cloud-signed release:

- It must be a **Team Key** (the "Team Keys" tab), **not an Individual Key**. An Individual
  key — even one owned by an Admin user — was rejected for cloud signing (export failed with
  `Cloud signing permission error` and xcodebuild fell back to a local Apple ID account).
- The key must have the **Admin** role. App Manager is not sufficient for cloud signing /
  distribution-certificate operations (same `Cloud signing permission error`). App Manager is
  only enough if you sign with a local `.p12` (see the fallback section).

Then **Download** the `.p8` (only downloadable once). Note the **Key ID** (10 chars) and the
**Issuer ID** (UUID) shown on that page.
- Apple: [Creating API keys for the App Store Connect API](https://developer.apple.com/documentation/appstoreconnectapi/creating-api-keys-for-app-store-connect-api)
- Apple: [App Store Connect API — Get started](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/)

### Cloud-managed signing certificate
Nothing to export — it is managed remotely by Apple and used automatically during the
cloud-signed archive/export. Background:
- Apple: [Cloud-managed certificates](https://developer.apple.com/help/account/certificates/cloud-managed-certificates/)
- WWDC21: [Distribute apps in Xcode with cloud signing](https://developer.apple.com/videos/play/wwdc2021/10204/)

## Environment variables

| Variable | Description |
|---|---|
| `ASC_KEY_ID` | 10-char App Store Connect API key ID |
| `ASC_ISSUER_ID` | App Store Connect issuer UUID |
| `ASC_KEY_P8_BASE64` | base64 of the `.p8` private key |
| `SKIP_KEYCHAIN=1` | **use cloud-managed signing** — no local certificate/keychain. This is the normal path for this project. |
| `ASC_DIST_CERT_P12_BASE64` | *(fallback only)* base64 of an Apple Distribution `.p12` (incl. private key) |
| `ASC_DIST_CERT_PASSWORD` | *(fallback only)* the `.p12` export password |
| `KEYCHAIN_PASSWORD` | *(fallback only, optional)* temp-keychain password (generated if unset) |

To base64-encode the key:

```sh
base64 -i AuthKey_XXXXXXXXXX.p8 | pbcopy   # -> ASC_KEY_P8_BASE64
```

All secrets are written to restricted temp locations and deleted on exit (success,
failure, or Ctrl-C) by a trap in `Scripts/release_env.sh`.

## How versioning fits the branch model

Version numbers live at the **project level** in `project.pbxproj` (inherited by the app +
extension targets). A version bump is a normal change that lands on **`dev`** and reaches
**`master`** through the reviewed `dev → master` merge — the release scripts **never** change
the version. Bumping is a separate step (`bump_version.sh`), and a release just reads whatever
version is already on `master` and tags it.

### Bumping the version (on dev)

```sh
Scripts/bump_version.sh 2.15.4        # optional 2nd arg sets the build number (default +1)
```

This branches off `dev`, bumps the project-level `MARKETING_VERSION` / `CURRENT_PROJECT_VERSION`,
pushes, and opens a PR into `dev` for review. Once merged and promoted to `master`, release it.

## Quick start (one command)

```sh
Scripts/release.sh          # reads the version already on master; add a version to sanity-check
```

`release.sh` orchestrates the release: it loads credentials from `.env` if present, prompts
for anything missing (offering to save them), reads the version on `master`, checks the tag,
prints a plan, and pauses before each outward-facing step. It runs:

1. `prepare_github_release.sh` — create the tag + GitHub draft release on `master` (no version change)
2. `build_release.sh --attach` — build, sign, export `session-<version>.ipa`, attach to the draft
3. `testflight_upload.sh` — upload the IPA to TestFlight

**Tag gating:** if `master`'s version has **no** tag yet, it creates the tag + draft and
proceeds. If a tag for that version **already exists** (i.e. the version hasn't been bumped
since the last release), it pauses so you can (1) re-check after merging a bump, (2) build and
submit with the current version anyway, or (3) abort.

Then it prints (and offers to open) the GitHub releases page and App Store Connect for the two
remaining manual actions: publishing the GitHub release and managing/submitting in TestFlight.

Useful flags: `-y/--yes` (no prompts, for CI), `--allow-existing-version` (build even if the
tag exists), `--skip-upload`, `--skip-draft`. Env: `RELEASE_REMOTE` (default `origin`),
`RELEASE_BRANCH` (default `master`). Run `Scripts/release.sh --help` for details.

### Using a `.env`

Put credentials in a `.env` at the repo root (git-ignored — never committed) so you don't
re-enter them each time. First interactive run offers to create it for you. Format:

```sh
ASC_KEY_ID="XXXXXXXXXX"
ASC_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
ASC_KEY_P8_BASE64="<base64 of AuthKey_XXXXXXXXXX.p8>"
SKIP_KEYCHAIN=1
```

## Running the steps individually

The orchestrator just calls these; run them directly if you need finer control. Credentials
come from the environment or `.env` (`build_release.sh` and `testflight_upload.sh` auto-load
`.env` via `release_env.sh`; set them explicitly if you're not using a `.env`):

```sh
export ASC_KEY_ID="XXXXXXXXXX"
export ASC_ISSUER_ID="xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
export ASC_KEY_P8_BASE64="$(base64 -i AuthKey_XXXXXXXXXX.p8)"
export SKIP_KEYCHAIN=1

Scripts/prepare_github_release.sh 2.15.4     # create tag + draft release on master
Scripts/build_release.sh 2.15.4 --attach     # version defaults to the project's if omitted
Scripts/testflight_upload.sh 2.15.4
gh release edit 2.15.4 --draft=false          # publish the GitHub release when ready
```

Outputs:
- `build/Session.xcarchive` — the archive, including `dSYMs/` for crash symbolication.
- `build/export/session-<version>.ipa` — the signed, App-Store-ready IPA (naming matches
  the historical builds in `~/Projects/Builds`).

## Notes

- **Version numbers** are set at the project level in `project.pbxproj` and inherited by
  the app + extension targets. `bump_version.sh` changes only those project-level values (on
  `dev`); the release scripts never modify them.
- **dSYMs**: `App_Store_Release` defaults to `DEBUG_INFORMATION_FORMAT = dwarf`; the device
  archive (`build_ci.sh archive-device`) overrides this to `dwarf-with-dsym` so symbols are
  produced and uploaded (`uploadSymbols` in `exportOptions.plist`).
- **CI**: there is intentionally no Drone deploy pipeline yet (matching Session Android).
  The scripts already read everything from env vars, so wiring them into CI later is just a
  matter of injecting the secrets above.
- `Scripts/testflight_upload.sh` is decoupled so you can re-upload an existing IPA without
  re-archiving. It uses `xcrun altool`; if Apple removes `altool`, switch it to
  `exportOptions.plist` `destination=upload` (drops the local artifact) or Transporter.

## Fallback: manual `.p12` signing (not needed for this project)

If a team is *not* using cloud-managed signing, provide an Apple Distribution certificate
instead of setting `SKIP_KEYCHAIN=1`: export the identity from Keychain Access as a `.p12`
(with its private key), then set `ASC_DIST_CERT_P12_BASE64` (=`base64 -i cert.p12`) and
`ASC_DIST_CERT_PASSWORD`. `release_env.sh` imports it into a temporary keychain for the build
and deletes it on exit. This project uses cloud signing, so this path should not be required.
