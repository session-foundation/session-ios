// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

// MARK: - Singleton

public extension Singleton {
    static let observationManager: SingletonConfig<ObservationManager> = Dependencies.create(
        identifier: "observationManager",
        createInstance: { dependencies in ObservationManager() }
    )
}

// MARK: - ObservableKey

public struct ObservableKey: Setting.Key, Sendable {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
}

// MARK: - ObservationManager

public actor ObservationManager {
    private var store: [ObservableKey: [UUID: AsyncStream<(Any?)>.Continuation]] = [:]
    private var pendingChanges: [ObservableKey: Any?] = [:]
    private var pendingChangeIndexes: [ObservableKey: Int] = [:]
    
    deinit {
        store.values.forEach { $0.values.forEach { $0.finish() } }
    }
    
    // MARK: - Functions
    
    public func observe(_ key: ObservableKey) -> AsyncStream<Any?> {
        let id: UUID = UUID()
        
        return AsyncStream { continuation in
            Task {
                addContinuation(continuation, for: key, id: id)
            }
            continuation.onTermination = { _ in
                Task { await self.removeContinuation(for: key, id: id) }
            }
        }
    }
    
    public func notify(_ changes: [ObservingDatabase.Change]) async {
        changes.forEach { change in
            pendingChanges[change.key] = change.value
            pendingChangeIndexes[change.key] = (pendingChanges.count - 1)
        }
        
        yieldAllPendingChanges()
    }
    
    public func yieldAllPendingChanges() {
        pendingChangeIndexes
            .sorted(by: { $0.value < $1.value })
            .compactMap { key, _ in pendingChanges[key].map { (key, $0) } }
            .forEach { key, value in
                store[key]?.values.forEach { $0.yield(value) }
            }
        pendingChanges.removeAll()
        pendingChangeIndexes.removeAll()
    }
    
    // MARK: - Internal Functions
    
    private func addContinuation(_ continuation: AsyncStream<(Any?)>.Continuation, for key: ObservableKey, id: UUID) {
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
    func notify(_ key: ObservableKey) async {
        await notify([(key, nil)])
    }
}
