// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public actor CurrentValueAsyncStream<Element: Sendable>: CancellationAwareStreamType {
    private let lifecycleManager: StreamLifecycleManager<Element> = StreamLifecycleManager()
    
    /// This is the most recently emitted value
    private var currentValue: Element
    
    // MARK: - Initialization

    public init(_ initialValue: Element) {
        self.currentValue = initialValue
    }
    
    // MARK: - Functions
    
    public func getCurrent() async -> Element {
        return currentValue
    }
    
    public func send(_ newValue: Element) async {
        currentValue = newValue
        lifecycleManager.send(newValue)
    }

    public func finishCurrentStreams() async {
        lifecycleManager.finishCurrentStreams()
    }
    
    public func beforeYield(to continuation: AsyncStream<Element>.Continuation) async {
        continuation.yield(currentValue)
    }
    
    public func makeTrackedStream() -> AsyncStream<Element> {
        lifecycleManager.makeTrackedStream().stream
    }
}
