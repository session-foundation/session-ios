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
    private var store: [ObservableKey: [UUID: AsyncStream<ObservedEvent>.Continuation]] = [:]
    
    deinit {
        store.values.forEach { $0.values.forEach { $0.finish() } }
    }
    
    // MARK: - Functions
    
    public func observe(_ key: ObservableKey) -> AsyncStream<ObservedEvent> {
        let id: UUID = UUID()
        
        return AsyncStream { continuation in
            Task { self.addContinuation(continuation, for: key, id: id) }
            
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(for: key, id: id) }
            }
        }
    }
    
    public func notify(_ changes: [ObservedEvent]) async {
        changes.forEach { event in
            store[event.key]?.values.forEach { $0.yield(event) }
        }
    }
    
    // MARK: - Internal Functions
    
    private func addContinuation(_ continuation: AsyncStream<ObservedEvent>.Continuation, for key: ObservableKey, id: UUID) {
        store[key, default: [:]][id] = continuation
    }
    
    private func removeContinuation(for key: ObservableKey, id: UUID) {
        store[key]?.removeValue(forKey: id)
        
        if store[key]?.isEmpty == true {
            store.removeValue(forKey: key)
        }
    }
}

// MARK: - Convenience

public extension ObservationManager {
    func notify(_ change: ObservedEvent) async {
        await notify([change])
    }
        
    func notify(_ key: ObservableKey, value: AnyHashable? = nil) async {
        await notify([ObservedEvent(key: key, value: value)])
    }
}
