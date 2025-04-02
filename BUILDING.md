# Building

We typically develop against the latest stable version of Xcode.

As of this writing, that's Xcode 16.2

## 1. Clone

Clone the repo to a working directory:

```
git clone https://github.com/session-foundation/session-ios.git
```

**Recommendation:**

We recommend you fork the repo on GitHub, then clone your fork:

```
git clone https://github.com/<USERNAME>/session-ios.git
```

You can then add the Session repo to sync with upstream changes:

```
git remote add upstream https://github.com/session-foundation/session-ios
```

## 2. Xcode

Open the `Session.xcodeproj` in Xcode.

```
open Session.xcodeproj
```

In the TARGETS area of the General tab, change the Team dropdown to your own. You will need to do that for all the listed targets, e.g. `Session`, `SessionShareExtension`, and `SessionNotificationServiceExtension`. You will need an Apple Developer account for this.

On the Capabilities tab, turn off Push Notifications and Data Protection, while keeping Background Modes on. The App Groups capability will need to remain on in order to access the shared data storage.

Build and Run and you are ready to go!

## Other

### Building libSession from source

The iOS project has a shared C++ library called `libSession` which is included via Swift Package Manager, it also supports building `libSession` from source (which can be cloned from https://github.com/session-foundation/libsession-util) by using the `Session_CompileLibSession` scheme and updating the `LIB_SESSION_SOURCE_DIR` build setting to point at the `libSession` source directory (currently it's set to `${SOURCE_DIR}/../LibSession-Util`)

In order for this to compile the following dependencies need to be installed:
- cmake
- m4
- pkg-config

These can be installed with Homebrew via `brew install cmake m4 pkg-config`

Additionally `xcode-select` needs to be setup correctly (depending on the order of installation it can point to the wrong directory and result in a build error similar to `tool '{name}' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance`), this can be setup correctly by running:

`sudo xcode-select -s /Applications/Xcode.app/Contents/Developer`

## Known issues

### Third-party Installation
The database for the app is stored within an `App Group` directory which is based on the app identifier, we have a script Build Phase which attempts to extract this and include it in the `Info.plist` for the project so we can access it at runtime (to reduce the manual handling other devs need to do) but if for some reason it's not working the fallback value can be updated within the `UserDefaults.applicationGroup` variable in `SessionUtilitiesKit/Types/UserDefaultsType` to match the value set for your project (You may also need to create the `App Group` on your Apple Developer account).

### Push Notifications
Features related to push notifications are known to be not working for third-party contributors since Apple's Push Notification service pushes will only work with the Session production code signing certificate.
