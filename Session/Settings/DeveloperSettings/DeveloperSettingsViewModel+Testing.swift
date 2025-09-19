// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit
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
        enum EnvironmentVariable: String {
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
        }
        
        ProcessInfo.processInfo.environment.forEach { key, value in
            guard let variable: EnvironmentVariable = EnvironmentVariable(rawValue: key) else { return }
            
            switch variable {
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
            }
        }
#endif
    }
}
