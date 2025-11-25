// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public struct GenericObservableKey: Setting.Key, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init(_ original: ObservableKey) { self.rawValue = original.generic.rawValue }
}

public struct ObservableKey: Setting.Key, Sendable {
    public let rawValue: String
    public let generic: GenericObservableKey
    internal let streamSource: ExternalStreamSource?
    
    public init(_ rawValue: String) {
        self.rawValue = rawValue
        self.generic = GenericObservableKey(rawValue)
        self.streamSource = nil
    }
    
    public init(_ rawValue: String, _ generic: GenericObservableKey?) {
        self.rawValue = rawValue
        self.generic = (generic ?? GenericObservableKey(rawValue))
        self.streamSource = nil
    }
    
    private init(rawValue: String, generic: GenericObservableKey, streamSource: ExternalStreamSource) {
        self.rawValue = rawValue
        self.generic = generic
        self.streamSource = streamSource
    }
    
    public static func stream<T: Sendable & Hashable>(
        key: String,
        generic: GenericObservableKey,
        _ streamProvider: @escaping @Sendable () async -> AsyncStream<T>?
    ) -> ObservableKey {
        return ObservableKey(
            rawValue: key,
            generic: generic,
            streamSource: ExternalStreamSource(id: key, stream: streamProvider)
        )
    }
}

public struct ObservedEvent: Hashable, Sendable {
    public let key: ObservableKey
    private let storedValue: AnySendableHashable?
    
    public var value: Any? { storedValue?.internalValue }
    
    public init<T: Hashable & Sendable>(key: ObservableKey, value: T?) {
        self.key = key
        self.storedValue = value.map { AnySendableHashable($0) }
    }
    
    public init(key: ObservableKey, value: None?) {
        self.key = key
        self.storedValue = value.map { AnySendableHashable($0) }
    }
    
    public init?(key: ObservableKey?, value: None?) {
        guard let key: ObservableKey = key else { return nil }
        
        self.key = key
        self.storedValue = value.map { AnySendableHashable($0) }
    }
}

public struct None: Hashable, Sendable {}

public struct AnySendableHashable: Hashable, Sendable {
    fileprivate let internalValue: any (Hashable & Sendable)
    public var value: Any { internalValue }

    public init<T: Hashable & Sendable>(_ value: T) {
        self.internalValue = value
    }

    // MARK: - Hashable Conformance
    
    public static func == (lhs: AnySendableHashable, rhs: AnySendableHashable) -> Bool {
        /// There isn't a way to compare two existentials types at the moment so we need to use this messy workaround to do so
        return lhs.box.isEqualTo(rhs.box)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(internalValue.hashValue)
    }

    private var box: AnyEquatableBox {
        return AnyEquatableBox(value: internalValue)
    }

    private struct AnyEquatableBox {
        let value: any (Hashable & Sendable)
        let isEqualTo: (AnyEquatableBox) -> Bool

        init<T: Hashable & Sendable>(value: T) {
            self.value = value
            self.isEqualTo = { other in
                guard let otherValue: T = other.value as? T else {
                    return false
                }
                
                return value == otherValue
            }
        }
    }
}

public struct ExternalStreamSource: Sendable, Hashable {
    public let id: String
    internal let makeStream: @Sendable () async -> AsyncStream<AnySendableHashable>?

    public init<T: Sendable & Hashable>(
        id: String,
        stream: @escaping @Sendable () async -> AsyncStream<T>?
    ) {
        self.id = id
        self.makeStream = {
            guard let concreteStream = await stream() else { return nil }
            
            return AsyncStream<AnySendableHashable> { continuation in
                let task = Task {
                    for await value in concreteStream {
                        continuation.yield(AnySendableHashable(value))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }
    
    public static func == (lhs: ExternalStreamSource, rhs: ExternalStreamSource) -> Bool {
        return lhs.id == rhs.id
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
