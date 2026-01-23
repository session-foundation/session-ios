// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit

// MARK: - Singleton

public extension Singleton {
    static let backgroundTaskManager: SingletonConfig<SessionBackgroundTaskManager> = Dependencies.create(
        identifier: "backgroundTaskManager",
        createInstance: { dependencies, _ in SessionBackgroundTaskManager(using: dependencies) }
    )
}

// MARK: - SessionBackgroundTaskState

public enum SessionBackgroundTaskState {
    case success
    case couldNotStart
    case expired
    case cancelled
}

// MARK: - SessionBackgroundTaskManager

public class SessionBackgroundTaskManager {
    /// Maximum duration to extend background tasks
    private static let maxBackgroundTime: TimeInterval = 180
    
    private let dependencies: Dependencies
    private let queue = DispatchQueue(label: "com.session.backgroundTaskManager")
    
    /// This property should only be accessed while synchronized on this instance.
    private var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    
    /// This property should only be accessed while synchronized on this instance
    var idCounter: UInt64 = 0
    
    /// Note that this flag is set a little early in "will resign active".
    ///
    /// This property should only be accessed while synchronized on this instance.
    private var isAppActive: Bool
    
    /// This property should only be accessed while synchronized on this instance.
    private var expirationMap: [UInt64: () -> ()] = [:]
    
    /// We use this timer to provide continuity and reduce churn,  so that if one SessionBackgroundTask ends right before another
    /// begins, we use a single uninterrupted background that spans their lifetimes.
    ///
    /// This property should only be accessed while synchronized on this instance.
    private var continuityTimer: DispatchSourceTimer?
    
    /// In order to ensure we have sufficient time to clean up before background tasks expire (without having to kick off additional tasks)
    /// we track the remaining background execution time and end tasks 5 seconds early (same as the AppDelegate background fetch)
    private var expirationTimeObserver: DispatchSourceTimer?
    private var hasGottenValidBackgroundTimeRemaining: Bool = false
    
    fileprivate init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.isAppActive = false
        
        Task { @MainActor [weak self] in
            self?.isAppActive = dependencies[singleton: .appContext].isMainAppAndActive
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Functions
    
    public func startObservingNotifications() {
        guard dependencies[singleton: .appContext].isMainApp else { return }
        
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: .sessionDidBecomeActive,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: .sessionWillResignActive,
            object: nil
        )
    }
    
    @objc private func applicationDidBecomeActive() {
        queue.sync { [weak self] in
            self?.isAppActive = true
            self?.ensureBackgroundTaskState()
        }
    }
    
    @objc private func applicationWillResignActive() {
        queue.sync { [weak self] in
            self?.isAppActive = false
            self?.ensureBackgroundTaskState()
        }
    }
    
    // MARK: - Background Task State Management
    
    // This method registers a new task with this manager.  We only bother
    // requesting a background task from iOS if the app is inactive (or about
    // to become inactive), so this will often not start a background task.
    //
    // Returns nil if adding this task _should have_ started a
    // background task, but the background task couldn't be begun.
    // In that case expirationBlock will not be called.
    fileprivate func addTask(expiration: @escaping () -> ()) -> UInt64? {
        return queue.sync { [weak self] () -> UInt64? in
            let taskId: UInt64 = ((self?.idCounter ?? 0) + 1)
            self?.idCounter = taskId
            self?.expirationMap[taskId] = expiration
            
            if self?.ensureBackgroundTaskState() != true {
                self?.expirationMap.removeValue(forKey: taskId)
            }
            
            if self?.continuityTimer != nil {
                self?.continuityTimer?.cancel()
                self?.continuityTimer = nil
            }
            
            // Start observing the background time remaining
            if self?.expirationTimeObserver?.isCancelled == true {
                self?.hasGottenValidBackgroundTimeRemaining = false
                self?.checkExpirationTime(in: .seconds(1))  // Don't know the remaining time so check soon
            }
            
            return taskId
        }
    }
    
    fileprivate func removeTask(taskId: UInt64?) {
        guard let taskId: UInt64 = taskId else { return }
        
        queue.sync { [weak self, queue] in
            self?.expirationMap.removeValue(forKey: taskId)
            
            // This timer will ensure that we keep the background task active (if necessary)
            // for an extra fraction of a second to provide continuity between tasks.
            // This makes it easier and safer to use background tasks, since most code
            // should be able to ensure background tasks by "narrowly" wrapping
            // their core logic with a SessionBackgroundTask and not worrying about "hand off"
            // between SessionBackgroundTasks.
            if self?.continuityTimer != nil {
                self?.continuityTimer?.cancel()
                self?.continuityTimer = nil
            }
            
            self?.continuityTimer = DispatchSource.makeTimerSource(queue: queue)
            self?.continuityTimer?.schedule(deadline: .now() + .milliseconds(250))
            self?.continuityTimer?.setEventHandler { self?.continuityTimerDidFire() }
            self?.continuityTimer?.resume()
            self?.ensureBackgroundTaskState()
        }
    }

    /// Begins or end a background task if necessary
    ///
    /// **Note:** Should only be called internally within `queue.sync` for thread safety
    @discardableResult private func ensureBackgroundTaskState() -> Bool {
        // We can't create background tasks in the SAE, but pretend that we succeeded.
        guard dependencies[singleton: .appContext].isMainApp else { return true }
        
        // We only want to have a background task if we are:
        // a) "not active" AND
        // b1) there is one or more active instance of SessionBackgroundTask OR...
        // b2) ...there _was_ an active instance recently.
        let shouldHaveBackgroundTask: Bool = (
            self.isAppActive == false && (
                self.expirationMap.count > 0 ||
                self.continuityTimer != nil
            )
        )
        let hasBackgroundTask: Bool = (self.backgroundTaskId != .invalid)

        guard shouldHaveBackgroundTask != hasBackgroundTask else {
            // Current state is correct
            return true
        }
        guard !shouldHaveBackgroundTask else {
            return (self.startOverarchingBackgroundTask() == true)
        }
        
        // Need to end background task.
        let maybeBackgroundTaskId: UIBackgroundTaskIdentifier? = self.backgroundTaskId
        self.backgroundTaskId = .invalid
        
        if self.expirationTimeObserver != nil {
            self.expirationTimeObserver?.cancel()
            self.expirationTimeObserver = nil
        }
        
        if let backgroundTaskId: UIBackgroundTaskIdentifier = maybeBackgroundTaskId, backgroundTaskId != .invalid {
            dependencies[singleton: .appContext].endBackgroundTask(backgroundTaskId)
        }
        
        return true
    }
    
    /// Returns `false` if the background task cannot be begun
    ///
    /// **Note:** Should only be called internally within `queue.sync` for thread safety
    private func startOverarchingBackgroundTask() -> Bool {
        guard dependencies[singleton: .appContext].isMainApp else { return false }
        
        self.backgroundTaskId = dependencies[singleton: .appContext].beginBackgroundTask { [weak self] in
            /// Supposedly `[UIApplication beginBackgroundTaskWithExpirationHandler]`'s handler
            /// will always be called on the main thread, but in practice we've observed otherwise.
            ///
            /// See:
            /// https://developer.apple.com/documentation/uikit/uiapplication/1623031-beginbackgroundtaskwithexpiratio)
            self?.queue.sync {
                self?.backgroundTaskExpired()
            }
        }
        
        // If the background task could not begin, return false to indicate that
        return (self.backgroundTaskId != .invalid)
    }
    
    /// **Note:** Should only be called internally within `queue.sync` for thread safety
    private func backgroundTaskExpired() {
        let backgroundTaskId: UIBackgroundTaskIdentifier = self.backgroundTaskId
        let expirationMap: [UInt64: () -> ()] = self.expirationMap
        self.backgroundTaskId = .invalid
        self.expirationMap.removeAll()
        
        if self.expirationTimeObserver != nil {
            self.expirationTimeObserver?.cancel()
            self.expirationTimeObserver = nil
        }
        
        /// Supposedly `[UIApplication beginBackgroundTaskWithExpirationHandler]`'s handler
        /// will always be called on the main thread, but in practice we've observed otherwise.  SessionBackgroundTask's
        /// API guarantees that completionBlock will always be called on the main thread, so we use DispatchSyncMainThreadSafe()
        /// to ensure that.  We thereby ensure that we don't end the background task until all of the completion blocks have completed.
        Threading.dispatchSyncMainThreadSafe { [dependencies] in
            expirationMap.values.forEach { expirationBlock in
                expirationBlock()
            }
            
            /// Apparently we need to "end" even expired background tasks.
            if backgroundTaskId != .invalid {
                dependencies[singleton: .appContext].endBackgroundTask(backgroundTaskId)
            }
        }
    }
    
    private func checkExpirationTime(in interval: DispatchTimeInterval) {
        expirationTimeObserver = DispatchSource.makeTimerSource(queue: queue)
        expirationTimeObserver?.schedule(deadline: .now() + interval)
        expirationTimeObserver?.setEventHandler { [weak self] in self?.expirationTimerDidFire() }
        expirationTimeObserver?.resume()
    }
    
    /// Timer will always fire on the `queue` so no need to `queue.sync`
    private func continuityTimerDidFire() {
        continuityTimer = nil
        ensureBackgroundTaskState()
    }
    
    /// Timer will always fire on the `queue` so no need to `queue.sync`
    private func expirationTimerDidFire() {
        expirationTimeObserver = nil
        
        guard dependencies[singleton: .appContext].isMainApp else { return }
        
        DispatchQueue.main.async { [weak self, queue, appContext = dependencies[singleton: .appContext]] in
            let backgroundTimeRemaining: TimeInterval = appContext.backgroundTimeRemaining
            
            queue.async { [weak self] in
                guard let self = self else { return }
                
                /// It takes the OS a little while to update the 'backgroundTimeRemaining' value so if it hasn't been updated yet then don't do anything
                guard self.hasGottenValidBackgroundTimeRemaining == true || backgroundTimeRemaining != .greatestFiniteMagnitude else {
                    self.checkExpirationTime(in: .seconds(1))
                    return
                }
                
                self.hasGottenValidBackgroundTimeRemaining = true
                
                switch backgroundTimeRemaining {
                    /// There is more than 10 seconds remaining so no need to do anything yet (plenty of time to continue running)
                    case 10...: self.checkExpirationTime(in: .seconds(5))
                        
                    /// There is between 5 and 10 seconds so poll more frequently just in case
                    case 5..<10: self.checkExpirationTime(in: .milliseconds(2500))
                        
                    /// There isn't a lot of time remaining so trigger the expiration
                    default: self.backgroundTaskExpired()
                }
            }
        }
    }
}

// MARK: - SessionBackgroundTask

public class SessionBackgroundTask {
    private let dependencies: Dependencies
    private var taskId: UInt64?
    private let label: String
    private var completion: ((SessionBackgroundTaskState) -> ())?
    
    // MARK: - Initialization
    
    public init(
        label: String,
        using dependencies: Dependencies,
        completion: @escaping (SessionBackgroundTaskState) -> () = { _ in }
    ) {
        self.dependencies = dependencies
        self.label = label
        self.completion = completion
        
        startBackgroundTask()
    }
    
    deinit {
        endBackgroundTask()
    }

    // MARK: - Functions
    
    private func startBackgroundTask() {
        taskId = dependencies[singleton: .backgroundTaskManager].addTask { [weak self] in
            self?.taskExpired()
        }
        
        if taskId == nil {
            completion?(.couldNotStart)
            completion = nil
        }
    }
    
    public func cancel() {
        guard taskId != nil else { return }
        
        dependencies[singleton: .backgroundTaskManager].removeTask(taskId: taskId)
        completion?(.cancelled)
        completion = nil
    }
    
    private func endBackgroundTask() {
        cancel()
    }
    
    private func taskExpired() {
        completion?(.expired)
        completion = nil
    }
}
