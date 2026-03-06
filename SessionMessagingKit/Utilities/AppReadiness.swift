// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let appReadiness: SingletonConfig<AppReadiness> = Dependencies.create(
        identifier: "appReadiness",
        createInstance: { _, _ in AppReadiness() }
    )
}

// MARK: - AppReadiness

public actor AppReadiness {
    nonisolated public let syncState: AppReadinessSyncState = AppReadinessSyncState()
    private let isAppReady: CurrentValueAsyncStream = CurrentValueAsyncStream(false)
    private var appWillBecomeReadyBlocks: [@MainActor () -> ()] = []
    private var appDidBecomeReadyBlocks: [@MainActor () -> ()] = []
    
    public func setAppReady() async {
        /// Store local copies so we can immediately clear them out
        let appWillBecomeReadyClosures: [@MainActor () -> ()] = appWillBecomeReadyBlocks
        let appDidBecomeReadyClosures: [@MainActor () -> ()] = appDidBecomeReadyBlocks
        appWillBecomeReadyBlocks = []
        appDidBecomeReadyBlocks = []
        
        /// Trigger the closures and update the flag
        await MainActor.run { [appWillBecomeReadyBlocks] in
            for closure in appWillBecomeReadyBlocks {
                closure()
            }
        }
        await isAppReady.send(true)
        syncState.update(isReady: true)
        await MainActor.run { [appDidBecomeReadyBlocks] in
            for closure in appDidBecomeReadyBlocks {
                closure()
            }
        }
    }
    
    public func invalidate() async {
        await isAppReady.send(false)
        syncState.update(isReady: false)
    }
    
    nonisolated public func runNowOrWhenAppWillBecomeReady(closure: @MainActor @escaping () -> ()) {
        // We don't need to do any "on app ready" work in the tests.
        guard !SNUtilitiesKit.isRunningTests else { return }
        
        Task(priority: .high) { [weak self] in
            guard await self?.isAppReady.getCurrent() != true else {
                return await MainActor.run {
                    closure()
                }
            }
            
            await self?.addWillBecomeReadyClosure(closure)
        }
    }
    
    nonisolated public func runNowOrWhenAppDidBecomeReady(closure: @MainActor @escaping () -> ()) {
        // We don't need to do any "on app ready" work in the tests.
        guard !SNUtilitiesKit.isRunningTests else { return }
        
        Task(priority: .high) { [weak self] in
            guard await self?.isAppReady.getCurrent() != true else {
                return await MainActor.run {
                    closure()
                }
            }
            
            await self?.addDidBecomeReadyClosure(closure)
        }
    }
    
    public func isReady() async {
        /// We don't need to do any "on app ready" work in the tests.
        guard !SNUtilitiesKit.isRunningTests else { return }
        
        /// Get the current `networkStatus`, if we are already ready then we can just stop immediately
        guard await isAppReady.getCurrent() != true else { return }
        
        /// Wait for the a `isAppReady` flat to be set to `true`
        _ = await isAppReady.stream.first(where: { $0 == true })
    }
    
    private func addWillBecomeReadyClosure(_ closure: @MainActor @escaping () -> ()) {
        appWillBecomeReadyBlocks.append(closure)
    }
    
    private func addDidBecomeReadyClosure(_ closure: @MainActor @escaping () -> ()) {
        appDidBecomeReadyBlocks.append(closure)
    }
}

// MARK: - AppReadinessSyncState

/// We manually handle thread-safety using the `NSLock` so can ensure this is `Sendable`
public final class AppReadinessSyncState: @unchecked Sendable {
    private let lock = NSLock()
    private var _isReady: Bool = false
    
    public var isReady: Bool { lock.withLock { _isReady } }

    func update(isReady: Bool) {
        lock.withLock { self._isReady = isReady }
    }
}
