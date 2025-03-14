// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit

// MARK: - Singleton

public extension Singleton {
    static let backgroundTaskManager: SingletonConfig<SessionBackgroundTaskManager> = Dependencies.create(
        identifier: "backgroundTaskManager",
        createInstance: { dependencies in SessionBackgroundTaskManager(using: dependencies) }
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
    private let dependencies: Dependencies
    
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
    private var continuityTimer: Timer?
    
    /// In order to ensure we have sufficient time to clean up before background tasks expire (without having to kick off additional tasks)
    /// we track the remaining background execution time and end tasks 5 seconds early (same as the AppDelegate background fetch)
    private var expirationTimeObserver: Timer?
    private var hasGottenValidBackgroundTimeRemaining: Bool = false
    
    fileprivate init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.isAppActive = dependencies[singleton: .appContext].isMainAppAndActive
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Functions
    
    @discardableResult private static func synced<T>(_ lock: Any, closure: () -> T) -> T {
        objc_sync_enter(lock)
        let result: T = closure()
        objc_sync_exit(lock)
        return result
    }
    
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
        SessionBackgroundTaskManager.synced(self) { [weak self] in
            self?.isAppActive = true
            self?.ensureBackgroundTaskState()
        }
    }
    
    @objc private func applicationWillResignActive() {
        SessionBackgroundTaskManager.synced(self) { [weak self] in
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
        return SessionBackgroundTaskManager.synced(self) { [weak self, dependencies] in
            let taskId: UInt64 = ((self?.idCounter ?? 0) + 1)
            self?.idCounter = taskId
            self?.expirationMap[taskId] = expiration
            
            if self?.ensureBackgroundTaskState() != true {
                self?.expirationMap.removeValue(forKey: taskId)
            }
            
            self?.continuityTimer?.invalidate()
            self?.continuityTimer = nil
            
            // Start observing the background time remaining
            if self?.expirationTimeObserver?.isValid != true {
                self?.hasGottenValidBackgroundTimeRemaining = false
                self?.expirationTimeObserver = Timer.scheduledTimerOnMainThread(
                    withTimeInterval: 1,
                    repeats: true,
                    using: dependencies,
                    block: { _ in self?.expirationTimerDidFire() }
                )
            }
            
            return taskId
        }
    }
    
    fileprivate func removeTask(taskId: UInt64?) {
        guard let taskId: UInt64 = taskId else { return }
        
        SessionBackgroundTaskManager.synced(self) { [weak self, dependencies] in
            self?.expirationMap.removeValue(forKey: taskId)
            
            // This timer will ensure that we keep the background task active (if necessary)
            // for an extra fraction of a second to provide continuity between tasks.
            // This makes it easier and safer to use background tasks, since most code
            // should be able to ensure background tasks by "narrowly" wrapping
            // their core logic with a SessionBackgroundTask and not worrying about "hand off"
            // between SessionBackgroundTasks.
            self?.continuityTimer?.invalidate()
            self?.continuityTimer = Timer.scheduledTimerOnMainThread(
                withTimeInterval: 0.25,
                using: dependencies,
                block: { _ in self?.continuityTimerDidFire() }
            )
            self?.ensureBackgroundTaskState()
        }
    }

    /// Begins or end a background task if necessary.
    @discardableResult private func ensureBackgroundTaskState() -> Bool {
        // We can't create background tasks in the SAE, but pretend that we succeeded.
        guard dependencies[singleton: .appContext].isMainApp else { return true }
        
        return SessionBackgroundTaskManager.synced(self) { [weak self, dependencies] in
            // We only want to have a background task if we are:
            // a) "not active" AND
            // b1) there is one or more active instance of SessionBackgroundTask OR...
            // b2) ...there _was_ an active instance recently.
            let shouldHaveBackgroundTask: Bool = (
                self?.isAppActive == false && (
                    (self?.expirationMap.count ?? 0) > 0 ||
                    self?.continuityTimer != nil
                )
            )
            let hasBackgroundTask: Bool = (self?.backgroundTaskId != .invalid)
    
            guard shouldHaveBackgroundTask != hasBackgroundTask else {
                // Current state is correct
                return true
            }
            guard !shouldHaveBackgroundTask else {
                return (self?.startBackgroundTask() == true)
            }
            
            // Need to end background task.
            let maybeBackgroundTaskId: UIBackgroundTaskIdentifier? = self?.backgroundTaskId
            self?.backgroundTaskId = .invalid
            self?.expirationTimeObserver?.invalidate()
            self?.expirationTimeObserver = nil
            
            if let backgroundTaskId: UIBackgroundTaskIdentifier = maybeBackgroundTaskId, backgroundTaskId != .invalid {
                dependencies[singleton: .appContext].endBackgroundTask(backgroundTaskId)
            }
            
            return true
        }
    }
    
    /// Returns `false` if the background task cannot be begun.
    private func startBackgroundTask() -> Bool {
        guard dependencies[singleton: .appContext].isMainApp else { return false }
        
        return SessionBackgroundTaskManager.synced(self) { [weak self, dependencies] in
            self?.backgroundTaskId = dependencies[singleton: .appContext].beginBackgroundTask {
                /// Supposedly `[UIApplication beginBackgroundTaskWithExpirationHandler]`'s handler
                /// will always be called on the main thread, but in practice we've observed otherwise.
                ///
                /// See:
                /// https://developer.apple.com/documentation/uikit/uiapplication/1623031-beginbackgroundtaskwithexpiratio)
                self?.backgroundTaskExpired()
            }
            
            // If the background task could not begin, return false to indicate that
            return (self?.backgroundTaskId != .invalid)
        }
    }
    
    private func backgroundTaskExpired() {
        var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
        var expirationMap: [UInt64: () -> ()] = [:]
        
        SessionBackgroundTaskManager.synced(self) { [weak self] in
            backgroundTaskId = (self?.backgroundTaskId ?? .invalid)
            self?.backgroundTaskId = .invalid
            self?.expirationTimeObserver?.invalidate()
            self?.expirationTimeObserver = nil
            
            expirationMap = (self?.expirationMap ?? [:])
            self?.expirationMap.removeAll()
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
    
    private func continuityTimerDidFire() {
        SessionBackgroundTaskManager.synced(self) { [weak self] in
            self?.continuityTimer?.invalidate()
            self?.continuityTimer = nil
            self?.ensureBackgroundTaskState()
        }
    }
    
    private func expirationTimerDidFire() {
        guard dependencies[singleton: .appContext].isMainApp else { return }
        
        let backgroundTimeRemaining: TimeInterval = dependencies[singleton: .appContext].backgroundTimeRemaining
        
        SessionBackgroundTaskManager.synced(self) { [weak self] in
            // It takes the OS a little while to update the 'backgroundTimeRemaining' value so if it hasn't been updated
            // yet then don't do anything
            guard self?.hasGottenValidBackgroundTimeRemaining == true || backgroundTimeRemaining != .greatestFiniteMagnitude else {
                return
            }
            
            self?.hasGottenValidBackgroundTimeRemaining = true
            
            // If there is more than 5 seconds remaining then no need to do anything yet (plenty of time to continue running)
            guard backgroundTimeRemaining <= 5 else { return }
            
            // There isn't a lot of time remaining so trigger the expiration
            self?.backgroundTaskExpired()
        }
    }
}

// MARK: - SessionBackgroundTask

public class SessionBackgroundTask {
    private let dependencies: Dependencies

    /// This property should only be accessed while synchronized on this instance
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
    
    @discardableResult private static func synced<T>(_ lock: Any, closure: () -> T) -> T {
        objc_sync_enter(lock)
        let result: T = closure()
        objc_sync_exit(lock)
        return result
    }
    
    private func startBackgroundTask() {
        // Make a local copy of completion to ensure that it is called exactly once
        var completion: ((SessionBackgroundTaskState) -> ())?
        
        self.taskId = dependencies[singleton: .backgroundTaskManager].addTask { [weak self] in
            Threading.dispatchMainThreadSafe {
                guard let strongSelf = self else { return }
                
                SessionBackgroundTask.synced(strongSelf) {
                    self?.taskId = nil
                    completion = self?.completion
                    self?.completion = nil
                }
                
                completion?(.expired)
            }
        }
        
        // If we didn't get a taskId then the background task could not be started so
        // we should call the completion block with a 'couldNotStart' error
        guard taskId == nil else { return }
        
        SessionBackgroundTask.synced(self) { [weak self] in
            completion = self?.completion
            self?.completion = nil
        }
        
        if completion != nil {
            Threading.dispatchMainThreadSafe {
                completion?(.couldNotStart)
            }
        }
    }
    
    public func cancel() {
        guard taskId != nil else { return }
        
        // Make a local copy of completion to ensure that it is called exactly once
        var completion: ((SessionBackgroundTaskState) -> ())?
        
        SessionBackgroundTask.synced(self) { [weak self, dependencies] in
            dependencies[singleton: .backgroundTaskManager].removeTask(taskId: self?.taskId)
            completion = self?.completion
            self?.taskId = nil
            self?.completion = nil
        }
        
        // endBackgroundTask must be called on the main thread.
        if completion != nil {
            Threading.dispatchMainThreadSafe {
                completion?(.cancelled)
            }
        }
    }
    
    private func endBackgroundTask() {
        guard taskId != nil else { return }
        
        // Make a local copy of completion since this method is called by `dealloc`
        var completion: ((SessionBackgroundTaskState) -> ())?
        
        SessionBackgroundTask.synced(self) { [weak self, dependencies] in
            dependencies[singleton: .backgroundTaskManager].removeTask(taskId: self?.taskId)
            completion = self?.completion
            self?.taskId = nil
            self?.completion = nil
        }
        
        // endBackgroundTask must be called on the main thread.
        if completion != nil {
            Threading.dispatchMainThreadSafe {
                completion?(.cancelled)
            }
        }
    }
}
