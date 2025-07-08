// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public struct GenericObservableKey: Setting.Key, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(_ original: ObservableKey) { self.rawValue = original.rawValue }
}

public struct ObservableKey: Setting.Key, Sendable {
    public let rawValue: String
    public let generic: GenericObservableKey
    
    public init(_ rawValue: String) {
        self.rawValue = rawValue
        self.generic = GenericObservableKey(rawValue)
    }
    
    public init(_ rawValue: String, _ generic: GenericObservableKey?) {
        self.rawValue = rawValue
        self.generic = (generic ?? GenericObservableKey(rawValue))
    }
}

public struct ObservedEvent: Hashable {
    public let key: ObservableKey
    public let value: AnyHashable?
    
    public init(key: ObservableKey, value: AnyHashable?) {
        self.key = key
        self.value = value
    }
}
