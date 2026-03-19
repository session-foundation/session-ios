// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine

// MARK: - ObservableKeyProvider

public protocol ObservableKeyProvider: Sendable, Equatable {
    var observedKeys: Set<ObservableKey> { get }
    
    func observedKeys(using dependencies: Dependencies) -> Set<ObservableKey>
}

public extension ObservableKeyProvider {
    func observedKeys(using dependencies: Dependencies) -> Set<ObservableKey> {
        return observedKeys
    }
}

// MARK: - ObservationBuilder DSL

public enum ObservationBuilder {
    public static func initialValue<Output: ObservableKeyProvider>(_ initialValue: Output) -> ObservationInitialValueBuilder<Output> {
        return ObservationInitialValueBuilder(initialValue: initialValue)
    }
    
    @discardableResult static func observe(
        _ keys: ObservableKey?...,
        priority: TaskPriority? = nil,
        using dependencies: Dependencies,
        closure: @escaping (ObservedEvent) async -> Void
    ) -> Task<Void, Never> {
        guard let finalKeys: [ObservableKey] = keys.compactMap({ $0 }).nullIfEmpty else {
            return Task { /* no-op */ }
        }
        
        return Task.detached(priority: priority) { [observationManager = dependencies[singleton: .observationManager]] in
            await withTaskGroup(of: Void.self) { [observationManager] group in
                for key in finalKeys {
                    group.addTask { [observationManager] in
                        do {
                            let stream = await observationManager.observe(key)
                            
                            for await event in stream {
                                try Task.checkCancellation()
                                
                                await closure(event)
                            }
                        }
                        catch { /* Ignore cancellation errors */ }
                    }
                }
            }
        }
    }
}

public struct ObservationInitialValueBuilder<Output: ObservableKeyProvider> {
    fileprivate let initialValue: Output
    
    public func using(dependencies: Dependencies) -> ObservationManagerBuilder<Output> {
        return ObservationManagerBuilder(
            initialValue: initialValue,
            observationManager: dependencies[singleton: .observationManager],
            dependencies: dependencies
        )
    }
}

public struct ObservationManagerBuilder<Output: ObservableKeyProvider> {
    fileprivate let initialValue: Output
    fileprivate let observationManager: ObservationManager
    fileprivate let dependencies: Dependencies

    public func query(
        _ query: @escaping @Sendable (_ previousValue: Output, _ events: [ObservedEvent], _ isInitialFetch: Bool, _ dependencies: Dependencies) async -> Output
    ) -> ConfiguredObservationBuilder<Output> {
        return ConfiguredObservationBuilder(
            dependencies: dependencies,
            initialValue: initialValue,
            observationManager: observationManager,
            query: query
        )
    }
}

// MARK: - ConfiguredObservationBuilder

public struct ConfiguredObservationBuilder<Output: ObservableKeyProvider> {
    fileprivate let dependencies: Dependencies
    fileprivate let initialValue: Output
    fileprivate let observationManager: ObservationManager
    fileprivate let query: @Sendable (_ previousValue: Output, _ events: [ObservedEvent], _ isInitialFetch: Bool, _ dependencies: Dependencies) async -> Output
    
    // MARK: - Outputs
    
    public func stream() -> AsyncStream<Output> {
        let (stream, continuation) = AsyncStream.makeStream(of: Output.self)
        let runner: QueryRunner = QueryRunner(
            observationManager: observationManager,
            initialValue: initialValue,
            continuation: continuation,
            query: query,
            using: dependencies
        )
        let observationTask: Task<Void, Never> = Task {
            await runner.run()
        }
        
        continuation.onTermination = { @Sendable _ in
            observationTask.cancel()
        }

        return stream
    }
    
    public func publisher() -> AnyPublisher<Output, Never> {
        let stream: AsyncStream<Output> = stream()
        let subject: CurrentValueSubject<Output, Never> = CurrentValueSubject(initialValue)
        let streamConsumingTask: Task<Void, Never> = Task {
            for await value in stream {
                if Task.isCancelled { break }
                subject.send(value)
            }
        }
        
        /// When the publisher subscription is cancelled, we cancel the task that's consuming the stream
        return subject
            .handleEvents(
                receiveCancel: {
                    streamConsumingTask.cancel()
                }
            )
            .compactMap { $0 }
            .eraseToAnyPublisher()
    }
    
    public func assign(using update: @escaping @MainActor (Output) -> Void) -> Task<Void, Never> {
        let stream: AsyncStream<Output> = stream()
        
        return Task {
            for await value in stream {
                if Task.isCancelled { break }
                
                await update(value)
            }
        }
    }
}

// MARK: - QueryRunner

private actor QueryRunner<Output: ObservableKeyProvider> {
    private let dependencies: Dependencies
    private let observationManager: ObservationManager
    private let debouncer: DebounceTaskManager<ObservedEvent> = DebounceTaskManager()
    private let continuation: AsyncStream<Output>.Continuation
    private let query: (_ previousValue: Output, _ events: [ObservedEvent], _ isInitialFetch: Bool, _ dependencies: Dependencies) async -> Output
    
    private var activeKeys: Set<ObservableKey> = []
    private var keyListenerTasks: [ObservableKey: Task<Void, Never>] = [:]
    private var lastValue: Output
    private var isRunningQuery: Bool = false
    private var pendingEvents: [ObservedEvent] = []
    private var hasPerformedInitialQuery: Bool = false
    
    // MARK: - Initialization

    init(
        observationManager: ObservationManager,
        initialValue: Output,
        continuation: AsyncStream<Output>.Continuation,
        query: @escaping (_ previousValue: Output, _ events: [ObservedEvent], _ isInitialFetch: Bool, _ dependencies: Dependencies) async -> Output,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.query = query
        self.observationManager = observationManager
        self.continuation = continuation
        self.lastValue = initialValue
    }
    
    // MARK: - Functions
    
    func run() async {
        /// Setup the debouncer to trigger a requery when events come through
        await debouncer.setAction { [weak self] events in
            await self?.process(events: events, isInitialQuery: false)
        }
        
        /// Perform initial query
        await process(events: [], isInitialQuery: true)
        
        /// Keep the `QueryRunner` alive until it's parent task is cancelled
        await TaskCancellation.wait()
        
        /// Cleanup resources immediately upon cancellation
        let tasksToCancel: [Task<Void, Never>] = Array(keyListenerTasks.values)
        keyListenerTasks.removeAll()
        activeKeys.removeAll()
        tasksToCancel.forEach { $0.cancel() }
        await debouncer.reset()
    }
    
    private func process(events: [ObservedEvent], isInitialQuery: Bool) async {
        pendingEvents.append(contentsOf: events)
        
        /// If the query is already running then just stop here, it'll automatically requery if there are any pending events remaining
        guard (isInitialQuery || !pendingEvents.isEmpty) && !isRunningQuery else { return }
        
        /// Not running a query so kick one off
        await runQueryLoop(isInitialQuery: isInitialQuery)
    }
    
    private func runQueryLoop(isInitialQuery: Bool) async {
        /// Sanity checks
        guard (isInitialQuery || !pendingEvents.isEmpty) && !isRunningQuery else { return }
        
        /// Store the state for this query
        let previousValueForQuery: Output = self.lastValue
        let eventsToProcess: [ObservedEvent] = pendingEvents
        pendingEvents.removeAll()
        isRunningQuery = true
        
        /// Capture the updated data and new keys to observe
        let newResult: Output = await self.query(previousValueForQuery, eventsToProcess, isInitialQuery, dependencies)
        let newKeys: Set<ObservableKey> = newResult.observedKeys(using: dependencies)

        /// If the keys have changed then we need to restart the observation
        if newKeys != activeKeys {
            let addedKeys: Set<ObservableKey> = newKeys.subtracting(activeKeys)
            let removedKeys: Set<ObservableKey> = activeKeys.subtracting(newKeys)
            activeKeys = newKeys
            
            /// Start observing new keys **before** cancelling anything
            for addedKey in addedKeys {
                keyListenerTasks[addedKey] = observe(key: addedKey)
            }
            
            /// Cancel tasks for and keys that were removed
            for removedKey in removedKeys {
                keyListenerTasks[removedKey]?.cancel()
                keyListenerTasks[removedKey] = nil
            }
        }
        
        /// Only yield the new result if the value has changed to prevent redundant updates
        if isInitialQuery || newResult != self.lastValue {
            self.lastValue = newResult
            continuation.yield(newResult)
        }
        
        /// We've finished running the query
        isRunningQuery = false
        
        /// If there are still events then we need to kick off another query
        if !pendingEvents.isEmpty {
            await runQueryLoop(isInitialQuery: false)
        }
    }
    
    private func observe(key: ObservableKey) -> Task<Void, Never> {
        return Task(priority: .utility) { [weak self] in
            guard let self = self else { return }
            
            do {
                if let source = key.streamSource {
                    if let stream = await source.makeStream() {
                        for await value in stream {
                            try Task.checkCancellation()
                            
                            let event = ObservedEvent(key: key, value: value)
                            await self.debouncer.signal(event: event)
                        }
                    }
                }
                else {
                    let stream = await self.observationManager.observe(key)
                    
                    for await event in stream {
                        try Task.checkCancellation()
                        
                        await self.debouncer.signal(event: event)
                    }
                }
            }
            catch {
                // A CancellationError could be thrown here but we just ignore it because
                // it'll generally just be the result of observing a new set of keys while
                // there are pending changes in the debouncer
            }
        }
    }
}
