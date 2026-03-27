// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UIKit.UIApplication

// MARK: - Singleton

public extension Singleton {
    static let observationManager: SingletonConfig<ObservationManager> = Dependencies.create(
        identifier: "observationManager",
        createInstance: { dependencies, _ in ObservationManager(using: dependencies) }
    )
}

// MARK: - ObservationManager

public actor ObservationManager {
    private struct BufferedEvent {
        let event: ObservedEvent
        let timestamp: Date
    }
    
    /// We buffer events during initial registration to close a race condition where events can fall through the cracks while settings up the
    /// observer - we need the window to be large enough to account for the worst case actor-hop, but not so large to have an excessive
    /// buffer size
    private let bufferWindow: TimeInterval = 0.1
    private let lifecycleObservations: [any NSObjectProtocol]
    private var eventBuffer: [ObservableKey: [BufferedEvent]] = [:]
    private var store: [ObservableKey: [UUID: AsyncStream<ObservedEvent>.Continuation]] = [:]
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        let notifications: [Notification.Name: AppLifecycle] = [
            UIApplication.didEnterBackgroundNotification: .didEnterBackground,
            UIApplication.willEnterForegroundNotification: .willEnterForeground,
            UIApplication.didBecomeActiveNotification: .didBecomeActive,
            UIApplication.willResignActiveNotification: .willResignActive,
            UIApplication.didReceiveMemoryWarningNotification: .didReceiveMemoryWarning,
            UIApplication.willTerminateNotification: .willTerminate
        ]
        
        lifecycleObservations = notifications.reduce(into: []) { [dependencies] result, next in
            let value: AppLifecycle = next.value
            
            result.append(
                NotificationCenter.default.addObserver(forName: next.key, object: nil, queue: .current) { [dependencies] _ in
                    Task(priority: .userInitiated) { [dependencies] in
                        await dependencies.notify(key: .appLifecycle(value))
                    }
                }
            )
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        store.values.forEach { $0.values.forEach { $0.finish() } }
    }
    
    // MARK: - Functions
    
    public func observe(_ key: ObservableKey) -> AsyncStream<ObservedEvent> {
        let id: UUID = UUID()
        
        return AsyncStream { continuation in
            self.addContinuation(continuation, for: key, id: id)
            
            /// Replay any buffered events within the window
            let now: Date = Date()
            eventBuffer[key]?
                .filter { now.timeIntervalSince($0.timestamp) < bufferWindow }
                .forEach { continuation.yield($0.event) }
            
            continuation.onTermination = { _ in
                Task(priority: .utility) { await self.removeContinuation(for: key, id: id) }
            }
        }
    }
    
    public func notify(events: [ObservedEvent]) async {
        let now: Date = Date()
        
        events.forEach { event in
            eventBuffer[event.key, default: []].append(BufferedEvent(event: event, timestamp: now))
            store[event.key]?.values.forEach { $0.yield(event) }
        }
        
        pruneBuffer(before: now.addingTimeInterval(-bufferWindow))
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
    
    private func pruneBuffer(before date: Date) {
        eventBuffer = eventBuffer.compactMapValues { events in
            let remaining: [BufferedEvent] = Array(events.drop(while: { $0.timestamp <= date }))
            
            return (remaining.isEmpty ? nil : remaining)
        }
    }
}

// MARK: - Convenience

public extension Dependencies {
    func notify(events: [ObservedEvent?]) async {
        guard let events: [ObservedEvent] = events.compactMap({ $0 }).nullIfEmpty else { return }
        
        await self[singleton: .observationManager].notify(events: events)
    }
    
    func notify<T: Hashable>(
        key: ObservableKey?,
        value: T?
    ) async {
        guard let event: ObservedEvent = key.map({ ObservedEvent(key: $0, value: value) }) else { return }
        
        await notify(events: [event])
    }
    
    func notify(key: ObservableKey) async {
        await notify(events: [ObservedEvent(key: key, value: nil)])
    }
    
    @discardableResult func notifyAsync(events: [ObservedEvent?]) -> Task<Void, Never> {
        return Task(priority: .userInitiated) { [weak self] in
            await self?.notify(events: events)
        }
    }
    
    @discardableResult func notifyAsync<T: Hashable>(
        key: ObservableKey?,
        value: T?
    ) -> Task<Void, Never> {
        return notifyAsync(events: [key.map { ObservedEvent(key: $0, value: value) }])
    }
    
    @discardableResult func notifyAsync(key: ObservableKey) -> Task<Void, Never> {
        return notifyAsync(events: [ObservedEvent(key: key, value: nil)])
    }
}
