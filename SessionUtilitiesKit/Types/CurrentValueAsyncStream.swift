// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public actor CurrentValueAsyncStream<Element: Sendable> {
    private var _currentValue: Element
    private let continuation: AsyncStream<Element>.Continuation
    public let stream: AsyncStream<Element>

    public var currentValue: Element { _currentValue }
    
    // MARK: - Initialization

    public init(_ initialValue: Element) {
        self._currentValue = initialValue

        /// We use `.bufferingNewest(1)` to ensure that the stream always holds the most recent value. When a new iterator is
        /// created for the stream, it will receive this buffered value first.
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: .bufferingNewest(1))
        self.stream = stream
        self.continuation = continuation
        self.continuation.yield(initialValue)
    }
    
    // MARK: - Functions

    public func send(_ newValue: Element) {
        _currentValue = newValue
        continuation.yield(newValue)
    }

    public func finish() {
        continuation.finish()
    }
}
