// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public actor DebounceTaskManager<Element> {
    private let debounceInterval: DispatchTimeInterval
    private var debounceTask: Task<Void, Never>? = nil
    private var action: (@Sendable (AsyncThrowingStream<Element, Error>.Continuation) async throws -> Void)?

    public init(debounceInterval: DispatchTimeInterval) {
        self.debounceInterval = debounceInterval
    }

    public func setAction(
        _ newAction: @Sendable @escaping (AsyncThrowingStream<Element, Error>.Continuation
    ) async throws -> Void) {
        self.action = newAction
    }

    public func signal(continuation: AsyncThrowingStream<Element, Error>.Continuation) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            guard let self = self else { return }

            do {
                try await Task.sleep(for: self.debounceInterval)
                guard !Task.isCancelled, await self.action != nil else { return }
                
                try await self.action?(continuation)
            } catch is CancellationError {
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    public func cancelPendingAction() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    public func reset() {
        cancelPendingAction()
        action = nil
    }
}
