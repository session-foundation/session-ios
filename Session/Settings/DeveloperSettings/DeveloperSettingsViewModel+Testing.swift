// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit
import SessionUIKit
import SessionNetworkingKit
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - Automated Test Convenience

extension DeveloperSettingsViewModel {
    /// Processes and sets feature flags based on environment variables when running in the iOS simulator to allow extenrally
    /// triggered automated tests to start in a specific state or with specific features enabled
    ///
    /// In order to use these with Appium (a UI testing framework used internally) these settings can be added to the device
    /// configuration as below, where the name of the value should match exactly to the `EnvironmentVariable` value
    /// below and the value should match one of the options documented below
    /// ```
    /// const iOSCapabilities: AppiumXCUITestCapabilities = {
    ///   'appium:processArguments': {
    ///     env: {
    ///       'serviceNetwork': 'testnet',
    ///       'animationsEnabled': 'false',
    ///       'debugDisappearingMessageDurations': 'true'
    ///     }
    ///   }
    /// }
    /// ```
    ///
    /// **Note:** All values need to be provided as strings (eg. booleans)
    static func processUnitTestEnvVariablesIfNeeded(using dependencies: Dependencies) async {
#if targetEnvironment(simulator)
        enum EnvironmentVariable: String, CaseIterable {
            /// Disables animations for the app (where possible)
            ///
            /// **Value:** `true`/`false` (default: `true`)
            case animationsEnabled
            
            /// Controls whether the "keys" for strings should be displayed instead of their localized values
            ///
            /// **Value:** `true`/`false` (default: `false`)
            case showStringKeys
            
            /// Controls whether pubkeys included in the logs should be truncated or not
            ///
            /// **Value:** `true`/`false` (default: `true` in debug builds, `false` otherwise)
            case truncatePubkeysInLogs
            
            /// Controls whether the app should trigger it's "Force Offline" behaviour (the network doesn't connect and all requests
            /// fail after a 1 second delay with a serviceUnavailable error)
            ///
            /// **Value:** `true`/`false` (default: `false`)
            case forceOffline
            
            /// Specifies the maximum number of files that can be uploaded/downloaded at the same time
            ///
            /// **Value:** `0-9,223,372,036,854,775,807` (default: `2`)
            case maxConcurrentFiles
            
            /// Controls which routing method the app uses to send network requets
            ///
            /// **Value:** `"onionRequests"`/`"sessionRouter"`/`"direct"` (default: `"onionRequests"`)
            ///
            /// **Note:** `direct` is not currently supported, so `onionRequests` will also be used in that case.
            case router
            
            /// Controls whether the app communicates with mainnet or testnet by default
            ///
            /// **Value:** `"mainnet"`/`"testnet"`/`"devnet"` (default: `"mainnet"`)
            ///
            /// **Note:** When set to `devnet` the `devnetPubkey`, `devnetIp`, `devnetHttpPort` and
            /// `devnetOmqPort` values all must be provided, if any are missing then `testnet` will be used instead
            case serviceNetwork
            
            /// Controls the pubkey which is used for the seed node when `devnet` is used
            ///
            /// **Value:** 64 character hex encoded public key
            ///
            /// **Note:** This will be ignored if `serviceNetwork` is not `devnet`
            case devnetPubkey
            
            /// Controls the ip address which is used for the seed node when `devnet` is used
            ///
            /// **Value:** IP address in the form of `"255.255.255.255"`
            ///
            /// **Note:** This will be ignored if `serviceNetwork` is not `devnet`
            case devnetIp
            
            /// Controls the port which is used for HTTP connections to the seed node when `devnet` is used
            ///
            /// **Value:** `0-65,535`
            ///
            /// **Note:** This will be ignored if `serviceNetwork` is not `devnet`
            case devnetHttpPort
            
            /// Controls the port which is used for QUIC connections to the seed node when `devnet` is used
            ///
            /// **Value:** `0-65,535`
            ///
            /// **Note:** This will be ignored if `serviceNetwork` is not `devnet`
            case devnetOmqPort
            
            /// Controls whether the app should offer the debug durations for disappearing messages (eg. `10s`, `30s`, etc.)
            ///
            /// **Value:** `true`/`false` (default: `false`)
            case debugDisappearingMessageDurations
            
            /// Controls the number of messages that the CommunityPoller should try to retrieve every time it polls
            ///
            /// **Value:** `1-256` (default: `100`, a value of `0` will use the default)
            case communityPollLimit
            
            /// Controls whether we should shorten the TTL of files to `60s` instead of the default on the File Server
            ///
            /// **Value:** `true`/`false` (default: `false`)
            case shortenFileTTL
            
            /// Controls the url which is used for the file server
            ///
            /// **Value:** Valid url string
            ///
            /// **Note:** If `customFileServerPubkey` isn't also provided then the default file server pubkey will be used
            case customFileServerUrl
            
            /// Controls the pubkey which is used for the file server
            ///
            /// **Value:** 64 character hex encoded public key
            ///
            /// **Note:** Only used if `customFileServerUrl` is valid
            case customFileServerPubkey
            
            /// Specifies a custom Date/Time that should be used by the app
            ///
            /// **Value:** Seconds since epoch
            ///
            /// **Note:** This value is static no matter how long the app runs for, additionally the service node network requires
            /// that device clocks are accurate within ~2 minutes so setting this value will generally result in network requests failing
            case customDateTime
            
            /// Specifies a custom Date/Time that the app was first installed
            ///
            /// **Value:** Seconds since epoch
            case customFirstInstallDateTime
            
            /// Controls the url which is used for the Session Pro backend
            ///
            /// **Value:** Valid url string
            ///
            /// **Note:** If `customProBackendPubkey` isn't also provided then the default Pro backend pubkey will be used
            case customProBackendUrl

            /// Controls the pubkey which is used for the Session Pro backend
            ///
            /// **Value:** 64 character hex encoded Ed25519 public key
            ///
            /// **Note:** Only used if `customProBackendUrl` is valid
            ///
            /// **Note:** This key is also what `libSession` verifies **other users'** pro proofs against, so every device in a
            /// test needs the same value - a device left on the default will read a custom-backend proof as invalid
            case customProBackendPubkey

            /// Simulates the Session Pro status the backend reports for the current user
            ///
            /// **Value:** `"useActual"`/`"never"`/`"active"`/`"expired"` (default: `"useActual"`)
            ///
            /// **Note:** These match the canonical wire codes (`BackendUserProStatus.neverCode` and friends) rather than the
            /// prettier `"neverBeenPro"`, so the test contract reads the same as what the backend actually sends
            ///
            /// **Note:** `unknown(code)` is intentionally not settable. It carries a free-form wire value for
            /// unrecognised/future codes and the type deliberately excludes it from `allCases` as "a real-backend value, not a
            /// dev-picker option" - and since it must never grant Pro (it fails closed, like `never`), a test wanting that
            /// behaviour should use `"never"`
            case mockCurrentUserSessionProBackendStatus

            /// Simulates whether this device holds a usable Pro **proof**, which is what grants access to Pro features -
            /// separately from `mockCurrentUserSessionProBackendStatus`, which only says what the backend *reports*
            ///
            /// **Note:** A mocked run holds no real proof, so a spec wanting a fully Pro client must set BOTH this and the
            /// backend status. Setting only the status yields display-Active-without-access, which is a real state (a plan
            /// is active but no proof has arrived yet) and the one the message-truncation behaviour lives in
            ///
            /// **Value:** `"valid"`/`"none"`/`"useActual"` (default: `"useActual"`)
            case mockCurrentUserSessionProProof

            /// Simulates the loading state of the Session Pro status request, letting a test reach the loading and
            /// backend-unavailable screens without having to take the backend down
            ///
            /// **Value:** `"useActual"`/`"loading"`/`"error"`/`"success"` (default: `"useActual"`)
            case mockCurrentUserSessionProLoadingState

            /// Simulates the platform the current user's subscription was originally purchased on
            ///
            /// **Value:** `"useActual"`/`"iOS"`/`"android"` (default: `"useActual"`)
            case mockCurrentUserSessionProOriginatingPlatform

            /// Simulates whether the current user's subscription was purchased on the account they're currently logged into, which is
            /// what drives the "non-originating account" screens
            ///
            /// **Value:** `"useActual"`/`"originatingAccount"`/`"nonOriginatingAccount"` (default: `"useActual"`)
            case mockCurrentUserOriginatingAccount

            /// Simulates whether the current user's subscription has a refund pending
            ///
            /// **Value:** `"useActual"`/`"notRefunding"`/`"refunding"` (default: `"useActual"`)
            case mockCurrentUserSessionProRefundingStatus

            /// Simulates whether the current user's plan renews itself, which is what the "Pro auto-renewing in
            /// {time}" line, the renewal-unsuccessful state and the Cancel Pro Access action all read
            ///
            /// **Value:** `"useActual"`/`"autoRenewing"`/`"notAutoRenewing"` (default: `"useActual"`)
            ///
            /// **Note:** `autoRenewing` is otherwise only ever written by a `get_pro_status` response, so without this
            /// a mocked run is always non-renewing and neither the cancel action nor the renewal-unsuccessful copy can
            /// be reached
            case mockCurrentUserSessionProAutoRenewing

            /// Simulates whether the store's own quick-refund window is still open, which decides between the
            /// <48h and >48h refund screens
            ///
            /// **Value:** `"useActual"`/`"open"`/`"closed"` (default: `"useActual"`)
            ///
            /// **Note:** The window is a property of the payment and a mocked run has no payment item, so the
            /// real value is always "closed" - the >48h screens are reachable without this, the <48h ones are not
            case mockCurrentUserSessionProQuickRefundWindow

            /// Simulates the build variant used by the Session Pro screens, which is what determines whether the app believes it has
            /// billing access
            ///
            /// **Value:** `"useActual"`/`"appStore"`/`"development"`/`"testFlight"`/`"ipa"`/`"apk"`/`"fDroid"`/`"huawei"`
            /// (default: `"useActual"`)
            ///
            /// **Note:** Only `appStore` and `testFlight` grant billing access, so any of the others are how a test reaches the
            /// "no billing access" screens
            case mockCurrentUserSessionProBuildVariant

            /// Simulates the timestamp at which the current user's Session Pro access expires
            ///
            /// **Value:** Seconds since epoch (default: unset, meaning the actual value is used)
            ///
            /// **Note:** A timestamp in the past is how a test reaches the expired states; this is separate from
            /// `mockCurrentUserSessionProBackendStatus`, which controls what the backend *reports*
            ///
            /// **Note:** As with `customDateTime`, the stored value loses some precision at present-day epoch values (observed
            /// rounding of up to ~a minute), so assert that a date is before/after a boundary rather than exactly equal to what
            /// was provided
            case mockCurrentUserAccessExpiryTimestamp
        }

        /// Resolves a mockable Session Pro feature from an environment variable value, returning `nil` (having logged) when the
        /// value isn't one of the documented options
        ///
        /// **Note:** The accepted strings are mapped explicitly rather than derived, because this is an **external contract** - the
        /// Appium suite is written against these names, so they should stay readable and stable independently of anything internal.
        /// Deriving them isn't viable either way: `MockableFeatureValue.rawValue` is an `Int`, so a derived contract would be numeric
        /// (`…BackendStatus=2`) rather than readable (`=active`) and would shift meaning if a type is ever renumbered, and deriving
        /// from `description` is worse still since some of these (eg. `SessionProUI.ClientPlatform`) return *display* text - which is
        /// exactly the kind of localized-string lookup that previously deadlocked the splash screen during feature-store init.
        func mockedProFeature<T: MockableFeatureValue>(
            _ value: String,
            for key: EnvironmentVariable,
            options: KeyValuePairs<String, T>
        ) -> MockableFeature<T>? {
            guard value != "useActual" else { return .useActual }

            guard let match: T = options.first(where: { $0.key == value })?.value else {
                let accepted: String = (["useActual"] + options.map { $0.key })
                    .map { "'\($0)'" }
                    .joined(separator: ", ")
                Log.error("Invalid '\(key.rawValue)' value '\(value)' provided, expected one of: \(accepted). Ignoring it rather than guessing.")
                return nil
            }

            return .simulate(match)
        }
        
        let envVars: [EnvironmentVariable: String] = ProcessInfo.processInfo.environment
            .reduce(into: [:]) { result, next in
                guard let variable: EnvironmentVariable = EnvironmentVariable(rawValue: next.key) else {
                    return
                }
                
                result[variable] = next.value
            }
        let allKeys: Set<EnvironmentVariable> = Set(envVars.keys)
        
        /// The order the the environment variables are applied in is important (configuring the network needs to happen in a certain
        /// order to simplify the below logic)
        for key in EnvironmentVariable.allCases {
            guard let value: String = envVars[key] else { continue }
            
            switch key {
                case .animationsEnabled:
                    dependencies.set(feature: .animationsEnabled, to: (value == "true"))
                    
                    guard value == "false" else { continue }
                    
                    await UIView.setAnimationsEnabled(false)
                    
                case .showStringKeys:
                    dependencies.set(feature: .showStringKeys, to: (value == "true"))
                    
                case .truncatePubkeysInLogs:
                    dependencies.set(feature: .truncatePubkeysInLogs, to: (value == "true"))
                    
                case .forceOffline:
                    dependencies.set(feature: .forceOffline, to: (value == "true"))
                    
                case .maxConcurrentFiles:
                    guard let intValue: Int = Int(value, radix: 10) else { continue }
                    
                    dependencies.set(feature: .maxConcurrentFiles, to: intValue)
                    
                case .router:
                    let router: Router
                    
                    switch value {
                        case "onionRequests": router = .onionRequests
                        case "sessionRouter": router = .sessionRouter
                        case "direct":
                            router = .onionRequests
                            Log.warn("Invalid router option '\(value)' provided, falling back to onion requests")
                            
                        default:
                            Log.warn("Invalid router option '\(value)' provided, falling back to onion requests")
                            router = .onionRequests
                    }
                    
                    dependencies.set(feature: .router, to: router)
                    
                case .serviceNetwork:
                    let (network, devnetConfig): (ServiceNetwork, ServiceNetwork.DevnetConfiguration?) = {
                        switch value {
                            case "testnet": return (.testnet, nil)
                            case "devnet":
                                /// Ensure values were provided first
                                guard
                                    let pubkey: String = envVars[.devnetPubkey],
                                    let ip: String = envVars[.devnetIp],
                                    let httpPort: String = envVars[.devnetHttpPort],
                                    let omqPort: String = envVars[.devnetOmqPort]
                                else {
                                    let requiredKeys: Set<EnvironmentVariable> = [
                                        .devnetPubkey,
                                        .devnetIp,
                                        .devnetHttpPort,
                                        .devnetOmqPort
                                    ]
                                    let missingKeys: Set<EnvironmentVariable> = requiredKeys.subtracting(allKeys)
                                    Log.warn("Using testnet as required devnet environment variables are missing: \(missingKeys.map { "'\($0.rawValue)'" }.joined(separator: ", "))")
                                    return (.testnet, nil)
                                }
                                
                                /// Validate each value
                                var errors: [String] = []
                                var finalHttpPort: UInt16 = 0
                                var finalOmqPort: UInt16 = 0
                                
                                if !Hex.isValid(pubkey) || pubkey.count != 64 {
                                    errors.append("'devnetPubkey' must be a 64 character hex string")
                                }
                                
                                if
                                    ip.split(separator: ".").count != 4 ||
                                    !ip.split(separator: ".").allSatisfy({ part in
                                        UInt8(part, radix: 10) != nil
                                    })
                                {
                                    errors.append("'devnetIp' must be in the format: '255.255.255.255'")
                                }
                                
                                if let parsedHttpPort: UInt16 = UInt16(httpPort, radix: 10) {
                                    finalHttpPort = parsedHttpPort
                                }
                                else {
                                    errors.append("'devnetHttpPort' must be a number between 0 and 65,535")
                                }
                                
                                if let parsedOmqPort: UInt16 = UInt16(omqPort, radix: 10) {
                                    finalOmqPort = parsedOmqPort
                                }
                                else {
                                    errors.append("'devnetOmqPort' must be a number between 0 and 65,535")
                                }
                                
                                guard errors.isEmpty else {
                                    Log.warn("Using testnet environment as devnet environment variables are invalid: \(errors.map { "\($0)" }.joined(separator: ", "))")
                                    return (.testnet, nil)
                                }
                                
                                /// We have a valid devnet config so use it
                                return (
                                    .devnet,
                                    ServiceNetwork.DevnetConfiguration(
                                        pubkey: pubkey,
                                        ip: ip,
                                        httpPort: finalHttpPort,
                                        omqPort: finalOmqPort
                                    )
                                )
                                
                            default: return (.mainnet, nil)
                        }
                    }()
                    
                    await DeveloperSettingsNetworkViewModel.updateEnvironment(
                        serviceNetwork: network,
                        devnetConfig: devnetConfig,
                        using: dependencies
                    )
                    
                /// These are handled in the `serviceNetwork` case
                case .devnetPubkey, .devnetIp, .devnetHttpPort, .devnetOmqPort: break
                    
                case .debugDisappearingMessageDurations:
                    dependencies.set(feature: .debugDisappearingMessageDurations, to: (value == "true"))
                    
                case .communityPollLimit:
                    guard
                        let intValue: Int = Int(value),
                        intValue >= 1 && intValue < 256
                    else { continue }
                    
                    dependencies.set(feature: .communityPollLimit, to: intValue)
                    
                case .shortenFileTTL:
                    dependencies.set(feature: .shortenFileTTL, to: (value == "true"))
                    
                case .customFileServerUrl:
                    /// Ensure values were provided first
                    guard let url: String = envVars[.customFileServerUrl], !url.isEmpty else {
                        Log.warn("An empty 'customFileServerUrl' was provided")
                        continue
                    }
                    let pubkey: String = (envVars[.customFileServerPubkey] ?? "")
                    let server: Network.FileServer.Custom = Network.FileServer.Custom(url: url, pubkey: pubkey)
                    
                    guard server.isValid else {
                        Log.warn("The custom file server info provided was not valid: (url: '\(url)', pubkey: '\(pubkey)'")
                        continue
                    }
                    dependencies.set(feature: .customFileServer, to: server)
                    
                /// This is handled in the `customFileServerUrl` case
                case .customFileServerPubkey: continue

                case .customProBackendUrl:
                    /// Ensure values were provided first
                    guard let url: String = envVars[.customProBackendUrl], !url.isEmpty else {
                        Log.warn("An empty 'customProBackendUrl' was provided")
                        continue
                    }
                    let proPubkey: String = (envVars[.customProBackendPubkey] ?? "")
                    let proBackend: Network.SessionPro.Custom = Network.SessionPro.Custom(
                        url: url,
                        pubkey: proPubkey
                    )

                    guard proBackend.isValid else {
                        Log.warn("The custom Pro backend info provided was not valid: (url: '\(url)', pubkey: '\(proPubkey)'")
                        continue
                    }
                    dependencies.set(feature: .customProBackend, to: proBackend)

                /// This is handled in the `customProBackendUrl` case
                case .customProBackendPubkey: continue

                case .customDateTime:
                    guard
                        let valueString: String = envVars[.customDateTime],
                        let value: TimeInterval = try? TimeInterval(valueString, format: .number)
                    else {
                        Log.warn("An invalid 'customDateTime' was provided")
                        continue
                    }
                    
                    dependencies.set(feature: .customDateTime, to: value)
                    
                case .customFirstInstallDateTime:
                    guard
                        let valueString: String = envVars[.customFirstInstallDateTime],
                        let value: TimeInterval = try? TimeInterval(valueString, format: .number)
                    else {
                        Log.warn("An invalid 'customFirstInstallDateTime' was provided")
                        continue
                    }
                    
                    dependencies.set(feature: .customFirstInstallDateTime, to: value)
                    
                case .mockCurrentUserSessionProBackendStatus:
                    guard
                        let mock: MockableFeature<Network.SessionPro.BackendUserProStatus> = mockedProFeature(
                            value,
                            for: key,
                            options: [
                                /// **Note:** `unknown(code)` is deliberately absent - the type excludes it from `allCases` as a
                                /// real-backend value rather than a dev-picker option, and it fails closed like `never` anyway
                                "never": .never,
                                "active": .active,
                                "expired": .expired
                            ]
                        )
                    else { continue }

                    dependencies.set(feature: .mockCurrentUserSessionProBackendStatus, to: mock)

                case .mockCurrentUserSessionProProof:
                    guard
                        let mock: MockableFeature<SessionPro.MockProofValidity> = mockedProFeature(
                            value,
                            for: key,
                            options: [
                                "valid": .valid,
                                "none": .none
                            ]
                        )
                    else { continue }

                    dependencies.set(feature: .mockCurrentUserSessionProProof, to: mock)

                case .mockCurrentUserSessionProLoadingState:
                    guard
                        let mock: MockableFeature<SessionPro.LoadingState> = mockedProFeature(
                            value,
                            for: key,
                            options: [
                                "loading": .loading,
                                "error": .error,
                                "success": .success
                            ]
                        )
                    else { continue }

                    dependencies.set(feature: .mockCurrentUserSessionProLoadingState, to: mock)

                case .mockCurrentUserSessionProOriginatingPlatform:
                    guard
                        let mock: MockableFeature<SessionProUI.ClientPlatform> = mockedProFeature(
                            value,
                            for: key,
                            options: [
                                "iOS": .iOS,
                                "android": .android
                            ]
                        )
                    else { continue }

                    dependencies.set(feature: .mockCurrentUserSessionProOriginatingPlatform, to: mock)

                case .mockCurrentUserOriginatingAccount:
                    guard
                        let mock: MockableFeature<SessionPro.OriginatingAccount> = mockedProFeature(
                            value,
                            for: key,
                            options: [
                                "originatingAccount": .originatingAccount,
                                "nonOriginatingAccount": .nonOriginatingAccount
                            ]
                        )
                    else { continue }

                    dependencies.set(feature: .mockCurrentUserOriginatingAccount, to: mock)

                case .mockCurrentUserSessionProRefundingStatus:
                    guard
                        let mock: MockableFeature<SessionPro.RefundingStatus> = mockedProFeature(
                            value,
                            for: key,
                            options: [
                                "notRefunding": .notRefunding,
                                "refunding": .refunding
                            ]
                        )
                    else { continue }

                    dependencies.set(feature: .mockCurrentUserSessionProRefundingStatus, to: mock)

                case .mockCurrentUserSessionProQuickRefundWindow:
                    guard
                        let mock: MockableFeature<SessionPro.MockQuickRefundWindow> = mockedProFeature(
                            value,
                            for: key,
                            options: [
                                "open": .open,
                                "closed": .closed
                            ]
                        )
                    else { continue }

                    dependencies.set(feature: .mockCurrentUserSessionProQuickRefundWindow, to: mock)

                case .mockCurrentUserSessionProAutoRenewing:
                    guard
                        let mock: MockableFeature<SessionPro.MockAutoRenewing> = mockedProFeature(
                            value,
                            for: key,
                            options: [
                                "autoRenewing": .autoRenewing,
                                "notAutoRenewing": .notAutoRenewing
                            ]
                        )
                    else { continue }

                    dependencies.set(feature: .mockCurrentUserSessionProAutoRenewing, to: mock)

                case .mockCurrentUserSessionProBuildVariant:
                    guard
                        let mock: MockableFeature<BuildVariant> = mockedProFeature(
                            value,
                            for: key,
                            options: [
                                "appStore": .appStore,
                                "development": .development,
                                "testFlight": .testFlight,
                                "ipa": .ipa,
                                "apk": .apk,
                                "fDroid": .fDroid,
                                "huawei": .huawei
                            ]
                        )
                    else { continue }

                    dependencies.set(feature: .mockCurrentUserSessionProBuildVariant, to: mock)

                case .mockCurrentUserAccessExpiryTimestamp:
                    guard let timestamp: TimeInterval = try? TimeInterval(value, format: .number) else {
                        Log.error("Invalid 'mockCurrentUserAccessExpiryTimestamp' value '\(value)' provided, expected seconds since epoch. Ignoring it rather than guessing.")
                        continue
                    }

                    dependencies.set(feature: .mockCurrentUserAccessExpiryTimestamp, to: timestamp)
            }
        }
#endif
    }
}
