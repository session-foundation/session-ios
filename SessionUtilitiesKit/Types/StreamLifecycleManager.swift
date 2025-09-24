// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public actor StreamLifecycleManager<Element: Sendable>: @unchecked Sendable {
    private var continuations: [UUID: AsyncStream<Element>.Continuation] = [:]
    
    // MARK: - Initialization
    
    public init() {}
    
    deinit {
        Task { [continuations = self.continuations] in
            for continuation in continuations.values {
                continuation.finish()
            }
        }
    }
    
    // MARK: - Internal Functions
    
    private func addContinuation(_ continuation: AsyncStream<Element>.Continuation, for id: UUID) {
        continuations[id] = continuation
    }
    
    private func removeContinuation(id: UUID) {
        continuations.removeValue(forKey: id)
    }
    
    // MARK: - Functions
    
    nonisolated func makeTrackedStream() -> (stream: AsyncStream<Element>, id: UUID) {
        let id: UUID = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: Element.self)
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeContinuation(id: id) }
        }
        
        Task { [weak self] in
            await self?.addContinuation(continuation, for: id)
        }
        
        return (stream, id)
    }
    
    func send(_ value: Element) {
        for continuation in continuations.values {
            continuation.yield(value)
        }
    }
    
    func finishStream(id: UUID) {
        if let continuation: AsyncStream<Element>.Continuation = continuations.removeValue(forKey: id) {
            continuation.finish()
        }
    }
    
    func finishCurrentStreams() {
        for continuation in continuations.values {
            continuation.finish()
        }
    
        continuations.removeAll()
    }
}
