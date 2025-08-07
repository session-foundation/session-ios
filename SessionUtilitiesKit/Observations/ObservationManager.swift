// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

// MARK: - Singleton

public extension Singleton {
    static let observationManager: SingletonConfig<ObservationManager> = Dependencies.create(
        identifier: "observationManager",
        createInstance: { dependencies in ObservationManager() }
    )
}

// MARK: - ObservationManager

public actor ObservationManager {
    private var store: [ObservableKey: [UUID: AsyncStream<(event: ObservedEvent, priority: Priority)>.Continuation]] = [:]
    
    deinit {
        store.values.forEach { $0.values.forEach { $0.finish() } }
    }
    
    // MARK: - Functions
    
    public func observe(_ key: ObservableKey) -> AsyncStream<(event: ObservedEvent, priority: Priority)> {
        let id: UUID = UUID()
        
        return AsyncStream { continuation in
            Task { self.addContinuation(continuation, for: key, id: id) }
            
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(for: key, id: id) }
            }
        }
    }
    
    public func notify(priority: Priority = .standard, events: [ObservedEvent]) async {
        events.forEach { event in
            store[event.key]?.values.forEach { $0.yield((event: event, priority: priority)) }
        }
    }
    
    // MARK: - Internal Functions
    
    private func addContinuation(_ continuation: AsyncStream<(event: ObservedEvent, priority: Priority)>.Continuation, for key: ObservableKey, id: UUID) {
        store[key, default: [:]][id] = continuation
    }
    
    private func removeContinuation(for key: ObservableKey, id: UUID) {
        store[key]?.removeValue(forKey: id)
        
        if store[key]?.isEmpty == true {
            store.removeValue(forKey: key)
        }
    }
}

// MARK: - ObservationManager.Priority

public extension ObservationManager {
    enum Priority {
        case standard   /// Goes through the standard debouncer
        case immediate  /// Flushes the debouncer forcing an immediate update with any pending events
                        
        var taskPriority: TaskPriority {
            switch self {
                case .standard: return .medium
                case .immediate: return .userInitiated
            }
        }
    }
}

// MARK: - Convenience

public extension Dependencies {
    @discardableResult func notifyAsync(
        priority: ObservationManager.Priority = .standard,
        events: [ObservedEvent?]
    ) -> Task<Void, Never> {
        guard let events: [ObservedEvent] = events.compactMap({ $0 }).nullIfEmpty else { return Task {} }
        
        return Task(priority: priority.taskPriority) { [observationManager = self[singleton: .observationManager]] in
            await observationManager.notify(priority: priority, events: events)
        }
    }
    
    @discardableResult func notifyAsync<T: Hashable>(
        priority: ObservationManager.Priority = .standard,
        key: ObservableKey?,
        value: T?
    ) -> Task<Void, Never> {
        guard let event: ObservedEvent = key.map({ ObservedEvent(key: $0, value: value) }) else { return Task {} }
        
        return notifyAsync(priority: priority, events: [event])
    }
    
    @discardableResult func notifyAsync(
        priority: ObservationManager.Priority = .standard,
        key: ObservableKey
    ) -> Task<Void, Never> {
        return notifyAsync(priority: priority, events: [ObservedEvent(key: key, value: nil)])
    }
}
