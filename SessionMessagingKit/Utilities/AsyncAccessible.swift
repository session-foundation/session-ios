// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

private let unsafeSyncQueue: DispatchQueue = DispatchQueue(label: "com.session.unsafeSyncQueue")

public protocol AsyncAccessible {}

public extension AsyncAccessible {

    /// This function blocks the current thread and waits for the result of the closure, use async/await functionality directly where possible
    /// as this approach could result in deadlocks
    nonisolated func unsafeSync<T>(_ closure: @escaping (Self) async -> T) -> T {
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        var result: T!  /// Intentionally implicitly unwrapped as we will wait undefinitely for it to return otherwise
        
        /// Run the task on a specific queue, not the global pool to try to force any unsafe execution to run serially
        unsafeSyncQueue.async { [self] in
            Task { [self] in
                result = await closure(self)
                semaphore.signal()
            }
        }
        semaphore.wait()
        
        return result
    }
}
