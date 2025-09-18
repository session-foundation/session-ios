// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public extension ObservableKey {
    static func appLifecycle(_ event: AppLifecycle) -> ObservableKey {
        ObservableKey("appLifecycle-\(event)", .appLifecycle)
    }
    
    static func databaseLifecycle(_ event: DatabaseLifecycle) -> ObservableKey {
        ObservableKey("databaseLifecycle-\(event)", .databaseLifecycle)
    }
    
    static func feature<T: FeatureOption>(_ key: FeatureConfig<T>) -> ObservableKey {
        ObservableKey(key.identifier, .feature)
    }
    
    static func featureGroup<T: FeatureOption>(_ config: FeatureConfig<T>) -> ObservableKey? {
        guard let groupIdentifier: String = config.groupIdentifier else { return nil }
        
        return ObservableKey("featureGroup-\(groupIdentifier)", .featureGroup)
    }
}

public extension GenericObservableKey {
    static let appLifecycle: GenericObservableKey = "appLifecycle"
    static let databaseLifecycle: GenericObservableKey = "databaseLifecycle"
    static let feature: GenericObservableKey = "feature"
    static let featureGroup: GenericObservableKey = "featureGroup"
}

// MARK: - AppLifecycle

public enum AppLifecycle: String, Sendable {
    case didEnterBackground
    case willEnterForeground
    case didBecomeActive
    case willResignActive
    case didReceiveMemoryWarning
    case willTerminate
}

// MARK: - DatabaseLifecycle

public enum DatabaseLifecycle: String, Sendable {
    case suspended
    case resumed
}
