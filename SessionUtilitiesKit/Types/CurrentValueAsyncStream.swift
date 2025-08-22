// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public actor CurrentValueAsyncStream<Element: Sendable> {
    private let lifecycleManager: StreamLifecycleManager<Element> = StreamLifecycleManager()
    
    /// This is the most recently emitted value
    public private(set) var currentValue: Element
    
    /// Every time `stream` is accessed it will create a **new** stream
    ///
    /// **Note:** This is non-isolated so it can be exposed via protocols without `async`, this is safe because `AsyncStream` is
    /// thread-safe internally and `Element` is `Sendable` so it's verified to be safe to send concurrently
    nonisolated public var stream: AsyncStream<Element> {
        AsyncStream { continuation in
            Task {
                await self.add(continuation: continuation)
            }
        }
    }
    
    // MARK: - Initialization

    public init(_ initialValue: Element) {
        self.currentValue = initialValue
    }
    
    // MARK: - Functions

    public func send(_ newValue: Element) {
        currentValue = newValue
        lifecycleManager.send(newValue)
    }

    public func finish() {
        lifecycleManager.finish()
    }
    
    // MARK: - Internal Functions
    
    private func add(continuation: AsyncStream<Element>.Continuation) {
        let id: UUID = lifecycleManager.track(continuation)

        continuation.onTermination = { @Sendable [lifecycleManager] _ in
            lifecycleManager.untrack(id: id)
        }
        
        /// Since we've added a new subscriber we need to yield the current value to them
        continuation.yield(currentValue)
    }
}
