// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine

// MARK: - ObservableKeyProvider

public protocol ObservableKeyProvider: Sendable, Equatable {
    var observedKeys: Set<ObservableKey> { get }
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
            return Task {}
        }
        
        return Task.detached(priority: priority) { [observationManager = dependencies[singleton: .observationManager]] in
            await withTaskGroup(of: Void.self) { [observationManager] group in
                for key in finalKeys {
                    group.addTask { [observationManager] in
                        do {
                            let stream = await observationManager.observe(key)
                            
                            for await event in stream {
                                try Task.checkCancellation()
                                
                                await closure(event.event)
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
    
    public func debounce(for interval: DispatchTimeInterval) -> ObservationDebounceBuilder<Output> {
        return ObservationDebounceBuilder(initialValue: initialValue, debounceInterval: interval)
    }
}

public struct ObservationDebounceBuilder<Output: ObservableKeyProvider> {
    fileprivate let initialValue: Output
    fileprivate let debounceInterval: DispatchTimeInterval
    
    public func using(dependencies: Dependencies) -> ObservationManagerBuilder<Output> {
        return ObservationManagerBuilder(
            initialValue: initialValue,
            debounceInterval: debounceInterval,
            observationManager: dependencies[singleton: .observationManager],
            dependencies: dependencies
        )
    }
}

public struct ObservationManagerBuilder<Output: ObservableKeyProvider> {
    fileprivate let initialValue: Output
    fileprivate let debounceInterval: DispatchTimeInterval
    fileprivate let observationManager: ObservationManager
    fileprivate let dependencies: Dependencies

    public func query(
        _ query: @escaping @Sendable (_ previousValue: Output, _ events: [ObservedEvent], _ isInitialFetch: Bool, _ dependencies: Dependencies) async -> Output
    ) -> ConfiguredObservationBuilder<Output> {
        return ConfiguredObservationBuilder(
            dependencies: dependencies,
            initialValue: initialValue,
            debounceInterval: debounceInterval,
            observationManager: observationManager,
            query: query
        )
    }
}

// MARK: - ConfiguredObservationBuilder

public struct ConfiguredObservationBuilder<Output: ObservableKeyProvider> {
    fileprivate let dependencies: Dependencies
    fileprivate let initialValue: Output
    fileprivate let debounceInterval: DispatchTimeInterval
    fileprivate let observationManager: ObservationManager
    fileprivate let query: @Sendable (_ previousValue: Output, _ events: [ObservedEvent], _ isInitialFetch: Bool, _ dependencies: Dependencies) async -> Output
    
    // MARK: - Outputs
    
    public func stream() -> AsyncStream<Output> {
        let (stream, continuation) = AsyncStream.makeStream(of: Output.self)
        let runner: QueryRunner = QueryRunner(
            observationManager: observationManager,
            initialValue: initialValue,
            debounceInterval: debounceInterval,
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
    private let debouncer: DebounceTaskManager<ObservedEvent>
    private let continuation: AsyncStream<Output>.Continuation
    private let query: (_ previousValue: Output, _ events: [ObservedEvent], _ isInitialFetch: Bool, _ dependencies: Dependencies) async -> Output
    
    private var activeKeys: Set<ObservableKey> = []
    private var listenerTask: Task<Void, Never>?
    private var lastValue: Output
    private var isRunningQuery: Bool = false
    private var pendingEvents: [ObservedEvent] = []
    private var hasPerformedInitialQuery: Bool = false
    
    // MARK: - Initialization

    init(
        observationManager: ObservationManager,
        initialValue: Output,
        debounceInterval: DispatchTimeInterval,
        continuation: AsyncStream<Output>.Continuation,
        query: @escaping (_ previousValue: Output, _ events: [ObservedEvent], _ isInitialFetch: Bool, _ dependencies: Dependencies) async -> Output,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.query = query
        self.observationManager = observationManager
        self.continuation = continuation
        self.debouncer = DebounceTaskManager(debounceInterval: debounceInterval)
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
        let newKeys: Set<ObservableKey> = newResult.observedKeys

        /// If the keys have changed then we need to restart the observation
        if newKeys != activeKeys {
            let oldListenerTask: Task<Void, Never>? = self.listenerTask
            
            listenerTask = Task { [weak self] in
                await self?.observe(keys: newKeys)
            }
            activeKeys = newKeys
            oldListenerTask?.cancel()
        }
        
        /// Only yielf the new result if the value has changed to prevent redundant updates
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
    
    private func observe(keys: Set<ObservableKey>) async {
        await withTaskGroup(of: Void.self) { group in
            for key in keys {
                group.addTask { [weak self] in
                    guard let self = self else { return }
                    
                    do {
                        let stream = await self.observationManager.observe(key)
                        
                        for await event in stream {
                            try Task.checkCancellation()
                            
                            switch event.priority {
                                case .standard: await self.debouncer.signal(event: event.event)
                                case .immediate: await self.debouncer.flush(event: event.event)
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
    }
}
