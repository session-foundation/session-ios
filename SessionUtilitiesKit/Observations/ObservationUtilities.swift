// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum EventDataRequirement {
    case databaseQuery
    case other
    case bothDatabaseQueryAndOther
}

public struct EventChangeset {
    public let databaseEvents: Set<ObservedEvent>
    private let eventsByKey: [GenericObservableKey: [ObservedEvent]]
    
    fileprivate init(
        databaseEvents: Set<ObservedEvent>,
        eventsByKey: [GenericObservableKey: [ObservedEvent]]
    ) {
        self.databaseEvents = databaseEvents
        self.eventsByKey = eventsByKey
    }
    
    // MARK: - Accessors
    
    /// Checks if any event matches the generic key
    public func contains(_ key: GenericObservableKey) -> Bool {
        return eventsByKey[key] != nil
    }
    
    /// Returns the most recent value for a specific key, cast to T
    public func latest<T>(_ key: GenericObservableKey, as type: T.Type = T.self) -> T? {
        return eventsByKey[key]?.last?.value as? T  /// The `last` event should be the newest
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
}

public extension Collection where Element == ObservedEvent {
    func split() -> EventChangeset {
        var allEvents: [GenericObservableKey: [ObservedEvent]] = [:]
        
        for event in self {
            allEvents[event.key.generic, default: []].append(event)
        }
        
        return EventChangeset(databaseEvents: [], eventsByKey: allEvents)
    }
    
    func split(
        by classifier: (ObservedEvent) -> EventDataRequirement
    ) -> EventChangeset {
        var dbEvents: Set<ObservedEvent> = []
        var allEvents: [GenericObservableKey: [ObservedEvent]] = [:]
        
        for event in self {
            allEvents[event.key.generic, default: []].append(event)
            
            switch classifier(event) {
                case .databaseQuery, .bothDatabaseQueryAndOther: dbEvents.insert(event)
                case .other: break
            }
        }
        
        return EventChangeset(databaseEvents: dbEvents, eventsByKey: allEvents)
    }
}
