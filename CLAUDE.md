# CLAUDE.md — Session iOS

Operational guide for AI agents working in this repo. For the "what and why" of the
system (module responsibilities, config sync, networking, message pipeline, Pro
subsystem, end-to-end flows), read **[ARCHITECTURE.md](ARCHITECTURE.md)** — it is
thorough and current. This file covers **how to work here**: build, test, conventions,
and gotchas. Don't duplicate architecture content into here.

## Project shape

- Xcode project: `Session.xcodeproj` (no CocoaPods/Pods despite `.gitignore` entries).
- In-project Swift frameworks + app target + 2 extensions. Dependency graph flows
  strictly downward — see ARCHITECTURE.md §5.2. Never introduce an upward import
  (e.g. `SessionUtilitiesKit` must not import `SessionMessagingKit`).
- Minimum deployment target iOS 15; builds against the iOS 26 SDK.
- libSession (the C/C++ core, repo `LibSession-Util`) is consumed via SPM and imported
  in Swift as **`import SessionUtil`**.

## Schemes

| Scheme | Use |
|---|---|
| `Session` | Main app + the scheme used for building and running all tests. |
| `Session_CompileLibSession` | Same app, but builds libSession **from source** instead of the prebuilt SPM binary. Use this when your change touches the C/C++ layer in `../LibSession-Util`. Requires `brew install cmake m4 pkg-config` and a correctly pointed `xcode-select` (see BUILDING.md). Point `LIB_SESSION_SOURCE_DIR` at the source (defaults to `${SOURCE_DIR}/../LibSession-Util`). |
| Per-framework schemes | `SessionMessagingKit`, `SessionNetworkingKit`, `SessionUIKit`, `SessionUtilitiesKit`, `SignalUtilitiesKit`, `TestUtilities`, and the two extensions — build a single module in isolation. |

Build configurations: `Debug` and `App_Store_Release` (plus `Debug_Compile_LibSession`
/ `App_Store_Release_Compile_LibSession` variants used by the compile-from-source scheme).

## Building & testing (local)

Prefer a plain `xcodebuild` invocation locally. Pick any installed simulator for the
destination (`xcrun simctl list devices available`).

Build:
```sh
xcodebuild build \
  -project Session.xcodeproj \
  -scheme Session \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Run a single test module (much faster than the whole suite):
```sh
xcodebuild test \
  -project Session.xcodeproj \
  -scheme Session \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:SessionUtilitiesKitTests
```

Notes:
- `Scripts/build_ci.sh test` exists but is **CI-flavoured** (bounces the simulator
  between suites, retries, parses xcresults, needs a passed-in simulator UUID). Use it
  only to reproduce CI behaviour, not for routine local runs.
- CI (Drone, `.drone.jsonnet`) builds under `App_Store_Release` and runs four suites:
  `SessionTests`, `SessionUtilitiesKitTests`, `SessionNetworkingKitTests`,
  `SessionMessagingKitTests`.
- Test targets exist per module. Shared mocking/fixtures/database helpers live in the
  `TestUtilities` target.

### End-to-end / regression tests (Appium)

Automated UI regression tests live in a **separate repository**, checked out alongside
this one as `Session_Appium` (repo: `session-appium`). They drive the built app through
Appium using Playwright as the runner, and cover both iOS and Android from one codebase
(specs are tagged `@ios` / `@android`). The in-repo Quick/Nimble suites do not cover
end-to-end UI flows — for regression coverage of a user-facing change, the corresponding
Appium tests need to run from that repo (e.g. `pnpm test-ios`). If a change warrants
regression testing, note that the Appium suite should be triggered there.

To run the suite locally: build the instrumented simulator `.app` (see **BUILDING.md →
"Building the app for the Appium regression suite"**), then follow `Session_Appium/CLAUDE.md`
for harness setup and the run commands.

## Testing conventions

- Tests are **Quick + Nimble** BDD specs, not XCTest. A test file is a `QuickSpec`
  subclass overriding `spec()`, structured with `describe` / `context` / `it`, and
  annotated with `// MARK: -`, `// MARK: --`, `// MARK: ----` comments mirroring the
  nesting depth. Match this style when adding tests.
- Components are tested in isolation by constructing a `Dependencies` container with
  mock implementations — no global singleton patching. Follow the existing pattern
  rather than reaching for real services.

## Code style & conventions

- **Prefer refactoring over duplication.** If you need behaviour that already exists,
  extract/reuse it rather than copy-pasting. Pull shared logic into the appropriate
  lower-level module rather than repeating it across call sites.
- **File header** (top of every new Swift file):
  `// Copyright © <year> Rangeproof Pty Ltd. All rights reserved.`
- **C++** is formatted with `.clang-format` (WebKit base, 120-column, no tabs).
- A `.swiftlint.yml` exists but SwiftLint is **not actually run** on this project — don't
  rely on it as a lint gate or spend effort satisfying it.
- SwiftUI-migrated types sometimes use a temporary `{name}_SwiftUI` suffix to coexist
  with their UIKit predecessor during the ongoing UIKit→SwiftUI migration (ARCHITECTURE.md
  §16.1, §23). This is a known transitional naming convention, not a mistake to "fix".
- Match the surrounding code's idioms in each module; they differ in age and style.

## Patterns you must respect (see ARCHITECTURE.md for detail)

- **Config-first shared state.** Anything that should sync across a user's devices is
  authored in the libSession config object first, then projected into GRDB for querying —
  not written directly to SQLite. (§7.2, §8)
- **JobRunner is a reliability primitive.** Work that must eventually complete across
  restarts/outages (send, upload, download, config sync) is modelled as a persistent job.
  Don't bypass it for such work. (§7.3)
- **ObservationManager drives UI reactivity** (progressively replacing GRDB
  `ValueObservation`). If UI isn't updating, check the relevant `ObservableKey` is emitted
  and observed. (§7.1)
- **Dependencies DI.** Services are resolved from an injected `Dependencies` container,
  not singletons. (§7.4, §17)

## Git / contribution flow

- `dev` is the active integration branch; `master` reflects the current production
  release. Releases are cut by merging `dev` → `master`, tagging, and releasing.
- Branch feature work off **`dev`** and merge back into `dev`; conflicts are resolved at
  merge time.
- Follow the repo default: commit/push or open PRs only when explicitly asked — leave
  git operations to the maintainer otherwise.

## Gotchas

- **Third-party signing / push:** push-notification features only work with the
  production signing cert; third-party contributors can't exercise them (BUILDING.md).
- **App Group container:** the app identifier / App Group is extracted into `Info.plist`
  by a build phase; if that fails, the fallback lives in
  `SessionUtilitiesKit/Types/UserDefaultsType` (`UserDefaults.applicationGroup`).
- **`0xDEAD10CC` / DB relocation:** the database currently lives in the App Group
  container, which risks the background file-access crash. A migration to the Documents
  directory is in progress and the extensions are being "de-databased" (ARCHITECTURE.md
  §23). Be careful adding new direct DB access from extensions.
- **libSession changes:** if you modify anything requiring a libSession source rebuild,
  switch to the `Session_CompileLibSession` scheme — the default scheme uses the prebuilt
  SPM binary and won't pick up local C/C++ edits.
