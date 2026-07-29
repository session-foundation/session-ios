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
    private let debouncer: DebounceTaskManager<ObservedEvent>
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

        /// Drop the debounce entirely when running synchronously (ie. in tests)
        ///
        /// The debounce is a real `Task.sleep`, so unlike the schedulers/queues it isn't neutralised by `forceSynchronous` - leaving it
        /// at the production interval means every observation-driven assertion has to out-wait it, which quietly makes those specs
        /// wall-clock dependent and intermittently slower than whatever deadline they picked
        self.debouncer = DebounceTaskManager(
            interval: (
                dependencies.forceSynchronous ?
                    .milliseconds(0) :
                    DebounceTaskManager<ObservedEvent>.defaultInterval
            )
        )
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
        ///
        /// **Note:** We record when the query started so that any key it turns out we need to observe can replay events emitted
        /// while it was running - we can't subscribe any earlier than this because the query is what tells us which keys to observe.
        /// This uses the wall clock rather than `dependencies.dateNow` deliberately, as it's compared against the manager's own
        /// buffer timestamps and must not be affected by a test freezing time.
        let queryStartedAt: Date = Date()
        let newResult: Output = await self.query(previousValueForQuery, eventsToProcess, isInitialQuery, dependencies)
        let newKeys: Set<ObservableKey> = newResult.observedKeys(using: dependencies)

        /// If the keys have changed then we need to restart the observation
        if newKeys != activeKeys {
            let addedKeys: Set<ObservableKey> = newKeys.subtracting(activeKeys)
            let removedKeys: Set<ObservableKey> = activeKeys.subtracting(newKeys)
            activeKeys = newKeys
            
            /// Start observing new keys **before** cancelling anything
            for addedKey in addedKeys {
                keyListenerTasks[addedKey] = await observe(key: addedKey, since: queryStartedAt)
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
    
    /// Start observing a key
    ///
    /// **Note:** The stream is acquired **before** this returns, so the continuation is registered as part of the key becoming active
    /// rather than whenever a spawned task happens to get scheduled. Previously the subscription happened inside the task, which
    /// meant a key could be active but unobserved for an unbounded period - any event emitted in that gap was recoverable only from
    /// the replay buffer, and if the task was starved for longer than that the event was silently lost. Only the *consumption* loop
    /// needs to be a task.
    ///
    /// - Parameter since: When this observation logically began, so the manager can replay anything emitted while the query that
    /// produced this key was still running (the keys aren't known until it finishes, so that window is unavoidable).
    private func observe(key: ObservableKey, since: Date) async -> Task<Void, Never> {
        /// An external source yields raw values rather than events, so it has to be wrapped separately
        if let source = key.streamSource {
            guard let stream = await source.makeStream() else { return Task {} }

            return Task(priority: .userInitiated) { [weak self] in
                do {
                    for await value in stream {
                        try Task.checkCancellation()

                        await self?.debouncer.signal(event: ObservedEvent(key: key, value: value))
                    }
                }
                catch {
                    // A CancellationError could be thrown here but we just ignore it because
                    // it'll generally just be the result of observing a new set of keys while
                    // there are pending changes in the debouncer
                }
            }
        }

        let stream: AsyncStream<ObservedEvent> = await observationManager.observe(key, since: since)

        return Task(priority: .userInitiated) { [weak self] in
            do {
                for await event in stream {
                    try Task.checkCancellation()

                    await self?.debouncer.signal(event: event)
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
