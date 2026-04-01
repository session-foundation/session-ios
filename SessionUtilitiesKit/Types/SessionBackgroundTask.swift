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
        
        /// The expiration handler, `onCancel`, and `defer` may all run concurrently so we need thread safety
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
            workTask.cancel()
            endTask()
        }
        taskIdBox.withLock { $0 = taskId }
        Log.info(.backgroundTask, "Starting background task: \(label) (\(taskId))")
        
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
}
