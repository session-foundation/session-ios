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
    
    // MARK: - Outputs
    
    public func stream() -> AsyncStream<Output> {
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
        
        continuation.onTermination = { @Sendable _ in
            observationTask.cancel()
        }

        return stream
    }
    
    public func publisher() -> AnyPublisher<Output, Never> {
        let stream: AsyncStream<Output> = stream()
        let subject: CurrentValueSubject<Output?, Never> = CurrentValueSubject(nil)
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
    private let observationManager: ObservationManager
    private let debouncer: DebounceTaskManager<ObservedEvent>
    private let continuation: AsyncStream<Output>.Continuation
    private let query: (_ previousValue: Output?, _ events: [ObservedEvent]) async -> Output
    
    private var activeKeys: Set<ObservableKey> = []
    private var listenerTask: Task<Void, Never>?
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
    }
    
    // MARK: - Functions
    
    func run() async {
        /// Setup the debouncer to trigger a requery when events come through
        await debouncer.setAction { [weak self] events in
            await self?.requery(changes: events)
        }
        
        /// Perform initial query
        await requery(changes: [])
        
        /// Keep the `QueryRunner` alive until it's parent task is cancelled
        await TaskCancellation.wait()
    }
    
    private func requery(changes: [ObservedEvent]) async {
        let previousValueForQuery: Output? = self.lastValue
        
        /// Capture the updated data and new keys to observe
        let newResult: Output = await self.query(previousValueForQuery, changes)
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
        
        /// Prevent redundant updates if the output hasn't changed.
        guard newResult != self.lastValue else { return }
        
        /// Publish the new result
        self.lastValue = newResult
        continuation.yield(newResult)
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
                            await self.debouncer.signal(event: event)
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
