// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine

// MARK: - ObservableKeyProvider

public protocol ObservableKeyProvider: Sendable, Equatable {
    var observedKeys: Set<ObservableKey> { get }
}

// MARK: - ObservationBuilder DSL

public enum ObservationBuilder {
    public static func debounce<Output: ObservableKeyProvider>(for interval: DispatchTimeInterval) -> ObservationDebounceBuilder<Output> {
        return ObservationDebounceBuilder(debounceInterval: interval)
    }
    
    public static func using<Output: Sendable & Equatable>(manager: ObservationManager) -> ObservationManagerBuilder<Output> {
        return ObservationManagerBuilder(
            debounceInterval: .milliseconds(250),
            observationManager: manager
        )
    }
}

public struct ObservationDebounceBuilder<Output: ObservableKeyProvider> {
    fileprivate let debounceInterval: DispatchTimeInterval
    
    public func using(manager: ObservationManager) -> ObservationManagerBuilder<Output> {
        return ObservationManagerBuilder(
            debounceInterval: debounceInterval,
            observationManager: manager
        )
    }
}

public struct ObservationManagerBuilder<Output: ObservableKeyProvider> {
    fileprivate let debounceInterval: DispatchTimeInterval
    fileprivate let observationManager: ObservationManager

    public func query(
        _ query: @escaping (_ previousValue: Output?, _ events: [ObservedEvent]) async -> Output
    ) -> ConfiguredObservationBuilder<Output> {
        return ConfiguredObservationBuilder(
            debounceInterval: debounceInterval,
            observationManager: observationManager,
            query: query
        )
    }
}

// MARK: - ConfiguredObservationBuilder

public struct ConfiguredObservationBuilder<Output: ObservableKeyProvider> {
    fileprivate let debounceInterval: DispatchTimeInterval
    fileprivate let observationManager: ObservationManager
    fileprivate let query: (_ previousValue: Output?, _ events: [ObservedEvent]) async -> Output

    // MARK: - Internal Functions
    
    private func makeObservationTask() -> (task: Task<Void, Never>, stream: AsyncStream<Output>) {
        let (stream, continuation) = AsyncStream.makeStream(of: Output.self)
        let runner: QueryRunner = QueryRunner(
            observationManager: observationManager,
            debounceInterval: debounceInterval,
            continuation: continuation,
            query: query
        )
        let observationTask: Task<Void, Never> = Task.detached {
            await runner.run()
        }

        return (observationTask, stream)
    }
    
    // MARK: - Outputs
    
    public func stream() -> AsyncStream<Output> {
        let (task, stream) = makeObservationTask()
        let (cancellableStream, continuation) = AsyncStream.makeStream(of: Output.self)

        Task {
            for await value in stream {
                continuation.yield(value)
            }
            continuation.finish()
        }
        
        continuation.onTermination = { @Sendable _ in
            task.cancel()
        }
        
        return cancellableStream
    }

    
    public func publisher(initialValue: Output) -> AnyPublisher<Output, Never> {
        let (task, stream) = makeObservationTask()
        let subject: CurrentValueSubject<Output, Never> = CurrentValueSubject(initialValue)
        let streamConsumingTask: Task<Void, Never> = Task {
            for await value in stream {
                if Task.isCancelled { break }
                subject.send(value)
            }
        }
        
        /// When the publisher subscription is cancelled, we cancel BOTH the underlying observation task and the task that's
        /// consuming the stream
        return subject.handleEvents(
            receiveCancel: {
                task.cancel()
                streamConsumingTask.cancel()
            }
        ).eraseToAnyPublisher()
    }
    
    public func assign(using update: @escaping @MainActor (Output) -> Void) -> Task<Void, Never> {
        let (task, stream) = makeObservationTask()
        let streamConsumingTask = Task {
            for await value in stream {
                if Task.isCancelled { break }
                
                await update(value)
            }
        }
        
        /// Create a "supervisor" task which cancells any child tasks when it gets cancelled
        let supervisorTask: Task<Void, Never> = Task { await task.value }

        return Task {
            await withTaskCancellationHandler {
                /// Keeps the supervisor task running until it's cancelled.
                await supervisorTask.value
            } onCancel: {
                task.cancel()
                streamConsumingTask.cancel()
            }
        }
    }
}

// MARK: - QueryRunner

private actor QueryRunner<Output: ObservableKeyProvider> {
    private let observationManager: ObservationManager
    private let debouncer: DebounceTaskManager<ObservedEvent>
    private let continuation: AsyncStream<Output>.Continuation
    private let query: (_ previousValue: Output?, _ events: [ObservedEvent]) async -> Output
    
    private var activeKeys: Set<ObservableKey> = []
    private var observationTask: Task<Void, Never>?
    private var lastValue: Output?
    
    // MARK: - Initialization

    init(
        observationManager: ObservationManager,
        debounceInterval: DispatchTimeInterval,
        continuation: AsyncStream<Output>.Continuation,
        query: @escaping (_ previousValue: Output?, _ events: [ObservedEvent]) async -> Output
    ) {
        self.query = query
        self.observationManager = observationManager
        self.continuation = continuation
        self.debouncer = DebounceTaskManager(debounceInterval: debounceInterval)
        
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.cancel() }
        }
    }
    
    // MARK: - Functions
    
    func run() async {
        await debouncer.setAction { [weak self] events in
            await self?.requery(changes: events)
        }
        
        await requery(changes: [])
    }
    
    private func requery(changes: [ObservedEvent]) async {
        let previousValue: Output? = self.lastValue
        
        /// Capture the updated data and new keys to observe
        let newResult: Output = await self.query(previousValue, changes)
        let newKeys: Set<ObservableKey> = newResult.observedKeys

        /// If the keys have changed then we need to restart the observation
        if newKeys != activeKeys {
            observationTask?.cancel()
            let newTask: Task<Void, Never> = Task { [weak self] in
                await self?.observe(keys: newKeys)
            }
            observationTask = newTask
            activeKeys = newKeys
        }
        
        /// Prevent redundant updates if the output hasn't changed.
        guard newResult != previousValue else { return }
        
        /// Publish the new result
        self.lastValue = newResult
        continuation.yield(newResult)
    }
    
    private func observe(keys: Set<ObservableKey>) async {
        var streams: [AsyncStream<ObservedEvent>] = []
        
        for key in keys {
            streams.append(await observationManager.observe(key))
        }
        
        /// Use a task group to merge all of the stream observations
        await withTaskGroup(of: Void.self) { group in
            for stream in streams {
                group.addTask { [weak self] in
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
    }
    
    private func cancel() async {
        observationTask?.cancel()
        observationTask = nil
        await debouncer.reset()
    }
}
