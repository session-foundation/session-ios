// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public struct EventHandlingStrategy: OptionSet, Hashable {
    public let rawValue: Int
        
    public init(rawValue: Int) {
        self.rawValue = rawValue
    }
    
    public static let none: EventHandlingStrategy = []
    public static let databaseQuery: EventHandlingStrategy = EventHandlingStrategy(rawValue: 1 << 0)
    public static let libSessionQuery: EventHandlingStrategy = EventHandlingStrategy(rawValue: 1 << 1)
    public static let directCacheUpdate: EventHandlingStrategy = EventHandlingStrategy(rawValue: 1 << 2)
}

public struct EventChangeset {
    public static let empty: EventChangeset = EventChangeset(eventsByKey: [:], eventsByStrategy: [:])
    
    private let eventsByKey: [GenericObservableKey: [ObservedEvent]]
    private let eventsByStrategy: [EventHandlingStrategy: Set<ObservedEvent>]
    
    fileprivate init(
        eventsByKey: [GenericObservableKey: [ObservedEvent]],
        eventsByStrategy: [EventHandlingStrategy: Set<ObservedEvent>]
    ) {
        self.eventsByKey = eventsByKey
        self.eventsByStrategy = eventsByStrategy
    }
    
    // MARK: - Generic Event Accessors
    
    public func events(matching strategy: EventHandlingStrategy) -> Set<ObservedEvent> {
        var result: Set<ObservedEvent> = []
        
        eventsByStrategy.forEach { key, events in
            if key.contains(strategy) {
                result.formUnion(events)
            }
        }
        
        return result
    }
    
    public var databaseEvents: Set<ObservedEvent> {
        return events(matching: .databaseQuery)
    }
    
    public var libSessionEvents: Set<ObservedEvent> {
        return events(matching: .libSessionQuery)
    }
    
    /// Checks if any event matches the generic key
    public func containsGeneric(_ key: GenericObservableKey) -> Bool {
        return containsAnyGeneric(key)
    }
    
    public func containsAnyGeneric(_ keys: GenericObservableKey...) -> Bool {
        return !Set(eventsByKey.keys).isDisjoint(with: Set(keys))
    }
    
    /// Returns the most recent value for a specific key, cast to T
    public func latestGeneric<T>(_ key: GenericObservableKey, as type: T.Type = T.self) -> T? {
        return eventsByKey[key]?.last?.value as? T  /// The `last` event should be the newest
    }
    
    /// Returns the most recent value for a specific key, cast to T that matches the condition
    public func latestGeneric<T>(_ key: GenericObservableKey, as type: T.Type = T.self, where condition: (T) -> Bool) -> T? {
        return eventsByKey[key]?
            .reversed()     /// The `last` event should be the newest so iterate backwards
            .first(where: {
                guard let value: T = $0.value as? T else { return false }
                
                return condition(value)
            }) as? T
    }
    
    /// Iterates over all events matching the key, casting them to T
    public func forEach<T>(
        _ key: GenericObservableKey,
        as type: T.Type = T.self,
        _ body: (T) -> Void
    ) {
        eventsByKey[key]?.forEach { event in
            if let value = event.value as? T {
                body(value)
            }
        }
    }
    
    /// Iterates over events matching the key, providing the full event (useful if you need the specific key ID)
    public func forEachEvent<T>(
        _ key: GenericObservableKey,
        as valueType: T.Type = T.self,
        _ body: (ObservedEvent, T) -> Void
    ) {
        eventsByKey[key]?.forEach { event in
            if let value = event.value as? T {
                body(event, value)
            }
        }
    }
    
    // MARK: - Explicit Event Accessors
    
    /// Checks if any event matches the generic key
    public func contains(_ key: ObservableKey) -> Bool {
        return containsAny(key)
    }
    
    public func containsAny(_ keys: ObservableKey...) -> Bool {
        return keys.contains { key in
            eventsByKey[key.generic]?.first(where: { $0.key == key }) != nil
        }
    }
    
    /// Returns the most recent value for a specific key, cast to T
    public func latest<T>(_ key: ObservableKey, as type: T.Type = T.self) -> T? {
        return eventsByKey[key.generic]?
            .reversed()     /// The `last` event should be the newest
            .first(where: { $0.key == key })?
            .value as? T
    }
    
    /// Returns the most recent value for a specific key, cast to T that matches the condition
    public func latest<T>(_ key: ObservableKey, as type: T.Type = T.self, where condition: (T) -> Bool) -> T? {
        return eventsByKey[key.generic]?
            .reversed()     /// The `last` event should be the newest so iterate backwards
            .first(where: {
                guard
                    $0.key == key,
                    let value: T = $0.value as? T
                else { return false }
                
                return condition(value)
            }) as? T
    }
}

public extension Collection where Element == ObservedEvent {
    func split() -> EventChangeset {
        var allEvents: [GenericObservableKey: [ObservedEvent]] = [:]
        
        for event in self {
            allEvents[event.key.generic, default: []].append(event)
        }
        
        return EventChangeset(eventsByKey: allEvents, eventsByStrategy: [:])
    }
    
    func split(
        by classifier: (ObservedEvent) -> EventHandlingStrategy
    ) -> EventChangeset {
        var allEvents: [GenericObservableKey: [ObservedEvent]] = [:]
        var eventsByStrategy: [EventHandlingStrategy: Set<ObservedEvent>] = [:]
        
        for event in self {
            allEvents[event.key.generic, default: []].append(event)
            
            let strategy: EventHandlingStrategy = classifier(event)
            eventsByStrategy[strategy, default: []].insert(event)
        }
        
        return EventChangeset(eventsByKey: allEvents, eventsByStrategy: eventsByStrategy)
    }
}
