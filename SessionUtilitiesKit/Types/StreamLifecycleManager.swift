// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

final class StreamLifecycleManager<Element: Sendable>: @unchecked Sendable {
    private let lock: NSLock = NSLock()
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    
    // MARK: - Initialization
    
    public init() {}
    
    deinit {
        finish()
    }
    
    // MARK: - Functions
    
    func track(_ continuation: AsyncStream<Element>.Continuation) -> UUID {
        let id: UUID = UUID()
        
        lock.withLock { continuations[id] = continuation }
        
        return id
    }
    
    func untrack(id: UUID) {
        _ = lock.withLock { continuations.removeValue(forKey: id) }
    }
    
    func send(_ value: Element) {
        /// Capture current continuations before sending to avoid deadlocks where yielding could result in a new continuation being
        /// added while the lock is held
        let currentContinuations: [UUID: AsyncStream<Element>.Continuation] = lock.withLock { continuations }
        
        for continuation in currentContinuations.values {
            continuation.yield(value)
        }
    }
    
    func finish() {
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
