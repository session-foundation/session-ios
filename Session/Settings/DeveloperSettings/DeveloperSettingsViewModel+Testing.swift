// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit
import SessionNetworkingKit
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
    static func processUnitTestEnvVariablesIfNeeded(using dependencies: Dependencies) {
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
            
            /// Controls whether the app communicates with mainnet or testnet by default
            ///
            /// **Value:** `"mainnet"`/`"testnet"` (default: `"mainnet"`)
            case serviceNetwork
            
            /// Controls whether the app should trigger it's "Force Offline" behaviour (the network doesn't connect and all requests
            /// fail after a 1 second delay with a serviceUnavailable error)
            ///
            /// **Value:** `true`/`false` (default: `false`)
            case forceOffline
            
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
                    
                    guard value == "false" else { return }
                    
                    UIView.setAnimationsEnabled(false)
                    
                case .showStringKeys:
                    dependencies.set(feature: .showStringKeys, to: (value == "true"))
                    
                case .truncatePubkeysInLogs:
                    dependencies.set(feature: .truncatePubkeysInLogs, to: (value == "true"))
                    
                case .serviceNetwork:
                    let network: ServiceNetwork
                    
                    switch value {
                        case "testnet": network = .testnet
                        default: network = .mainnet
                    }
                    
                    DeveloperSettingsViewModel.updateServiceNetwork(to: network, using: dependencies)
                    
                case .forceOffline:
                    dependencies.set(feature: .forceOffline, to: (value == "true"))
                    
                case .debugDisappearingMessageDurations:
                    dependencies.set(feature: .debugDisappearingMessageDurations, to: (value == "true"))
                    
                case .communityPollLimit:
                    guard
                        let intValue: Int = Int(value),
                        intValue >= 1 && intValue < 256
                    else { return }
                    
                    dependencies.set(feature: .communityPollLimit, to: intValue)
                    
                case .shortenFileTTL:
                    dependencies.set(feature: .shortenFileTTL, to: (value == "true"))
                    
                case .customFileServerUrl:
                    /// Ensure values were provided first
                    guard let url: String = envVars[.customFileServerUrl], !url.isEmpty else {
                        Log.warn("An empty 'customFileServerUrl' was provided")
                        break
                    }
                    let pubkey: String = (envVars[.customFileServerPubkey] ?? "")
                    let server: Network.FileServer.Custom = Network.FileServer.Custom(url: url, pubkey: pubkey)
                    
                    guard server.isValid else {
                        Log.warn("The custom file server info provided was not valid: (url: '\(url)', pubkey: '\(pubkey)'")
                        break
                    }
                    dependencies.set(feature: .customFileServer, to: server)
                    
                /// This is handled in the `customFileServerUrl` case
                case .customFileServerPubkey: break
                    
                case .customDateTime:
                    guard
                        let valueString: String = envVars[.customDateTime],
                        let value: TimeInterval = try? TimeInterval(valueString, format: .number)
                    else {
                        Log.warn("An invalid 'customDateTime' was provided")
                        break
                    }
                    
                    dependencies.set(feature: .customDateTime, to: value)
                    
                case .customFirstInstallDateTime:
                    guard
                        let valueString: String = envVars[.customFirstInstallDateTime],
                        let value: TimeInterval = try? TimeInterval(valueString, format: .number)
                    else {
                        Log.warn("An invalid 'customFirstInstallDateTime' was provided")
                        break
                    }
                    
                    dependencies.set(feature: .customFirstInstallDateTime, to: value)
            }
        }
#endif
    }
}
