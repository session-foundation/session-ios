// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit


// MARK: - Log.Category

private extension Log.Category {
    static let backgroundTask: Log.Category = .create("SessionBackgroundTask", defaultLevel: .info)
}

// MARK: - SessionBackgroundTask

public enum SessionBackgroundTask {
    private final class Locked<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        
        init(_ value: T) { self.value = value }
        
        func withLock<R>(_ block: (inout T) -> R) -> R {
            lock.withLock { block(&value) }
        }
    }
    
    /// Runs the `work` inside a background task so the system won't suspend the app while the closure executes
    public static func run<T: Sendable>(
        label: String,
        priority: TaskPriority? = nil,
        using dependencies: Dependencies,
        _ work: @escaping () async throws -> T
    ) async throws -> T {
        guard dependencies[singleton: .appContext].isMainApp else {
            return try await work()
        }
        
        /// Use a continuation to bridge the sync expiration handler into Swift cancellation, fired proactively with ~5s remaining
        let workTask: Task<T, Error> = Task(priority: priority) { try await work() }
        let (taskId, endTask) = begin(label: label, using: dependencies) { workTask.cancel() }
        
        return try await withTaskCancellationHandler(
            operation: {
                defer {
                    Log.info(.backgroundTask, "Background task completed (\(taskId))")
                    endTask()
                }
                
                return try await workTask.value
            },
            onCancel: {
                Log.info(.backgroundTask, "Background task cancelled (\(taskId))")
                workTask.cancel()
                endTask()
            }
        )
    }
    
    /// Begins a background task before returning, for work that must be covered from a synchronous point onwards (`run` only
    /// begins one once its caller gets to run), the returned `end` closure must be called once the work is done
    public static func begin(
        label: String,
        using dependencies: Dependencies,
        onExpiration: @escaping () -> Void = {}
    ) -> (id: UIBackgroundTaskIdentifier, end: () -> Void) {
        guard dependencies[singleton: .appContext].isMainApp else { return (.invalid, {}) }
        
        /// The expiration handler and the caller's `end` may run concurrently so we need thread safety
        let taskIdBox = Locked<UIBackgroundTaskIdentifier>(.invalid)
        let endTask: () -> Void = {
            let id: UIBackgroundTaskIdentifier = taskIdBox.withLock { id -> UIBackgroundTaskIdentifier in
                let current = id
                
                /// Replace the stored value with `invalid` to prevent calling `endBackgroundTask` more than once
                id = .invalid
                return current
            }
            
            guard id != .invalid else { return }
            dependencies[singleton: .appContext].endBackgroundTask(id)
        }

        let taskId: UIBackgroundTaskIdentifier = dependencies[singleton: .appContext].beginBackgroundTask {
            onExpiration()
            endTask()
        }
        taskIdBox.withLock { $0 = taskId }
        Log.info(.backgroundTask, "Starting background task: \(label) (\(taskId))")
        
        return (taskId, endTask)
    }
}
