// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension AsyncSequence {
    func asAsyncStream() -> AsyncStream<Element> {
        AsyncStream { continuation in
            let task: Task<Void, Error> = Task {
                for try await element in self {
                    continuation.yield(element)
                }
                
                continuation.finish()
            }
            
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

public extension AsyncSequence where Element: Equatable {
    func removeDuplicates() -> AsyncThrowingStream<Element, Error> {
        return AsyncThrowingStream { continuation in
            let task = Task {
                var previousElement: Element? = nil
                
                do {
                    for try await element in self {
                        if Task.isCancelled { break }
                        
                        if element != previousElement {
                            continuation.yield(element)
                            previousElement = element
                        }
                    }
                    
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}
