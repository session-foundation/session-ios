// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension AsyncSequence where Element: Sendable {
    /// Transforms elements from an upstream sequence into a new sequence, observing only the values from the most recently
    /// transformed sequence.
    ///
    /// This is a more intuitively named alias for `flatMapLatest`.
    ///
    /// When the upstream sequence produces a new element, the operator cancels observation of the previously produced inner
    /// sequence and **switches** to observing the new one.
    ///
    /// **Note:** Internally this function uses an `Actor` to safely manage the state of switching between inner streams, this is
    /// especially needed on iOS 15 as in early versions of async/await in Swift there were race conditions which could crash.
    func switchMap<S: AsyncSequence>(_ transform: @escaping @Sendable (Element) async -> S) -> AsyncStream<S.Element> where S.Element: Sendable {
        flatMapLatest(transform)
    }

    /// Transforms the elements of an async sequence into a new async sequence, flattening the result.
    ///
    /// This operator is equivalent to `switchMap` or `flatMapLatest` in other reactive frameworks - when the upstream sequence
    /// produces a new element, the operator cancels the observation of the previously produced inner sequence and switches to
    /// observing the new one.
    ///
    /// This is particularly useful for "stream of streams" scenarios, like observing a value on a dependency that can itself be replaced.
    ///
    /// - Parameter transform: An async, throwing closure that takes an element from the upstream sequence and returns a
    /// new `AsyncSequence` to be observed.
    /// - Returns: An `AsyncStream` that emits elements from the latest inner sequence.
    ///
    /// **Note:** Internally this function uses an `Actor` to safely manage the state of switching between inner streams, this is
    /// especially needed on iOS 15 as in early versions of async/await in Swift there were race conditions which could crash.
    func flatMapLatest<S: AsyncSequence>(
        _ transform: @escaping @Sendable (Element) async -> S
    ) -> AsyncStream<S.Element> where S.Element: Sendable {
        return AsyncStream { continuation in
            let actor = FlatMapLatestActor(continuation: continuation, transform: transform)
            let outerTask = Task {
                do {
                    for try await element in self {
                        await actor.switchTo(element: element)
                    }
                    
                    await actor.finish()
                } catch {
                    await actor.finish(with: error)
                }
            }

            continuation.onTermination = { @Sendable _ in
                outerTask.cancel()
            }
        }
    }
}

private actor FlatMapLatestActor<UpstreamElement, InnerSequence: AsyncSequence> where UpstreamElement: Sendable, InnerSequence.Element: Sendable {
    private let continuation: AsyncStream<InnerSequence.Element>.Continuation
    private let transform: @Sendable (UpstreamElement) async -> InnerSequence
    private var currentInnerTask: Task<Void, Error>?

    init(
        continuation: AsyncStream<InnerSequence.Element>.Continuation,
        transform: @escaping @Sendable (UpstreamElement) async -> InnerSequence
    ) {
        self.continuation = continuation
        self.transform = transform
    }

    func switchTo(element: UpstreamElement) async {
        currentInnerTask?.cancel()
        currentInnerTask = Task {
            let innerSequence = await transform(element)
            
            for try await innerElement in innerSequence {
                let result = continuation.yield(innerElement)
                
                switch result {
                    case .terminated: return
                    default: break
                }
            }
        }
    }
    
    func finish(with error: Error? = nil) {
        currentInnerTask?.cancel()
        continuation.finish()
    }
}
