// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public extension ObservableKey {
    static func feature<T: FeatureOption>(_ key: FeatureConfig<T>) -> ObservableKey {
        ObservableKey(key.identifier, .feature)
    }
    
    static func featureGroup<T: FeatureOption>(_ config: FeatureConfig<T>) -> ObservableKey? {
        guard let groupIdentifier: String = config.groupIdentifier else { return nil }
        
        return ObservableKey("featureGroup-\(groupIdentifier)", .featureGroup)
    }
}

public extension GenericObservableKey {
    static let feature: GenericObservableKey = "feature"
    static let featureGroup: GenericObservableKey = "featureGroup"
}
