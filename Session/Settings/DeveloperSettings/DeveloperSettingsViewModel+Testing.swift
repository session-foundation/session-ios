// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit
import SessionUtilitiesKit
import SessionNetworkingKit

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
            
            /// Controls which routing method the app uses to send network requets
            ///
            /// **Value:** `"onionRequests"`/`"lokinet"`/`"direct"` (default: `"onionRequests"`)
            ///
            /// **Note:** When set to `lokinet` the `serviceNetwork` **MUST** be set to `testnet` will be used
            /// if it's not then `onionRequests` will be used. Additionally `direct` is not currently supported, so
            /// `onionRequests` will also be used in that case.
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
                    
                    await UIView.setAnimationsEnabled(false)
                    
                case .showStringKeys:
                    dependencies.set(feature: .showStringKeys, to: (value == "true"))
                    
                case .truncatePubkeysInLogs:
                    dependencies.set(feature: .truncatePubkeysInLogs, to: (value == "true"))
                    
                case .forceOffline:
                    dependencies.set(feature: .forceOffline, to: (value == "true"))
                    
                case .router:
                    let router: Router
                    
                    switch value {
                        case "onionRequests": router = .onionRequests
                        case "lokinet":
                            if envVars[.serviceNetwork] != "testnet" {
                                Log.warn("Router option '\(value)' can only be used on 'testnet', falling back to onion requests")
                                router = .onionRequests
                            }
                            else {
                                router = .lokinet
                            }
                            
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
                    else { return }
                    
                    dependencies.set(feature: .communityPollLimit, to: intValue)
            }
        }
#endif
    }
}
