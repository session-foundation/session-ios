// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public final class StreamLifecycleManager<Element: Sendable>: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    
    // MARK: - Initialization
    
    public init() {}
    
    deinit {
        finishCurrentStreams()
    }
    
    // MARK: - Functions
    
    func makeTrackedStream() -> (stream: AsyncStream<Element>, id: UUID) {
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
        let id: UUID = UUID()
        
        lock.withLock { continuations[id] = continuation }

        continuation.onTermination = { @Sendable [self] _ in
            self.finishStream(id: id)
        }
        
        return (stream, id)
    }
    
    func send(_ value: Element) {
        /// Capture current continuations before sending to avoid deadlocks where yielding could result in a new continuation being
        /// added while the lock is held
        let currentContinuations: [UUID: AsyncStream<Element>.Continuation] = lock.withLock { continuations }
        
        for continuation in currentContinuations.values {
            continuation.yield(value)
        }
    }
    
    func finishStream(id: UUID) {
        lock.withLock {
            if let continuation: AsyncStream<Element>.Continuation = continuations.removeValue(forKey: id) {
                continuation.finish()
            }
        }
    }
    
    func finishCurrentStreams() {
        let currentContinuations: [UUID: AsyncStream<Element>.Continuation] = lock.withLock {
            let continuationsToFinish: [UUID: AsyncStream<Element>.Continuation] = continuations
            continuations.removeAll()
            return continuationsToFinish
        }
        
        for continuation in currentContinuations.values {
            continuation.finish()
        }
    }
}
