// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

// MARK: - CancellationAwareAsyncStream

public actor CancellationAwareAsyncStream<Element: Sendable>: CancellationAwareStreamType {
    private let lifecycleManager: StreamLifecycleManager<Element> = StreamLifecycleManager()
    
    // MARK: - Initialization

    public init() {}
    
    // MARK: - Functions

    public func send(_ newValue: Element) async {
        lifecycleManager.send(newValue)
    }

    public func finishCurrentStreams() async {
        lifecycleManager.finishCurrentStreams()
    }
    
    public func beforeYield(to continuation: AsyncStream<Element>.Continuation) async {
        // No-op - no initial value
    }
    
    public func _makeTrackedStream() -> AsyncStream<Element> {
        lifecycleManager.makeTrackedStream().stream
    }
}

// MARK: - CancellationAwareStreamType

public protocol CancellationAwareStreamType: Actor {
    associatedtype Element: Sendable
    
    func send(_ newValue: Element) async
    func finishCurrentStreams() async
    
    /// This function gets called when a stream is initially created but before the inner stream is created, it shouldn't be called directly
    func beforeYield(to continuation: AsyncStream<Element>.Continuation) async
    
    /// This is an internal function which shouldn't be called directly
    func _makeTrackedStream() async -> AsyncStream<Element>
}

public extension CancellationAwareStreamType {
    /// Every time `stream` is accessed it will create a **new** stream
    ///
    /// **Note:** This is non-isolated so it can be exposed via protocols without `async`, this is safe because `AsyncStream` is
    /// thread-safe internally and `Element` is `Sendable` so it's verified to be safe to send concurrently
    nonisolated var stream: AsyncStream<Element> {
        AsyncStream { continuation in
            let bridgingTask = Task {
                await self.beforeYield(to: continuation)
                
                let internalStream: AsyncStream<Element> = await self._makeTrackedStream()
                
                for await element in internalStream {
                    continuation.yield(element)
                }
                
                continuation.finish()
            }
            
            continuation.onTermination = { @Sendable _ in
                bridgingTask.cancel()
            }
        }
    }
}
