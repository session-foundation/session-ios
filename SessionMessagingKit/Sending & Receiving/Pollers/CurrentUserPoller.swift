// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

public final class CurrentUserPoller: Poller {
    public static var namespaces: [SnodeAPI.Namespace] = [
        .default, .configUserProfile, .configContacts, .configConvoInfoVolatile, .configUserGroups
    ]

    // MARK: - Settings
    
    override var namespaces: [SnodeAPI.Namespace] { CurrentUserPoller.namespaces }
    override var pollerQueue: DispatchQueue { Threading.pollerQueue }
    
    /// After polling a given snode 6 times we always switch to a new one.
    ///
    /// The reason for doing this is that sometimes a snode will be giving us successful responses while
    /// it isn't actually getting messages from other snodes.
    override var pollDrainBehaviour: SwarmDrainBehaviour { .limitedReuse(count: 6) }
    
    private let pollInterval: TimeInterval = 1.5
    private let retryInterval: TimeInterval = 0.25
    private let maxRetryInterval: TimeInterval = 15
    
    // MARK: - Convenience Functions
    
    public func start(using dependencies: Dependencies = Dependencies()) {
        let publicKey: String = getUserHexEncodedPublicKey(using: dependencies)
        
        guard isPolling[publicKey] != true else { return }
        
        SNLog("Started polling.")
        super.startIfNeeded(for: publicKey, using: dependencies)
    }
    
    public func stop() {
        SNLog("Stopped polling.")
        super.stopAllPollers()
    }
    
    // MARK: - Abstract Methods
    
    // stringlint:ignore_contents
    override public func pollerName(for publicKey: String) -> String {
        return "Main Poller"
    }
    
    override func nextPollDelay(for publicKey: String, using dependencies: Dependencies) -> TimeInterval {
        let failureCount: TimeInterval = TimeInterval(failureCount[publicKey] ?? 0)
        
        // Scale the poll delay based on the number of failures
        return min(maxRetryInterval, pollInterval + (retryInterval * (failureCount * 1.2)))
    }
    
    override func handlePollError(_ error: Error, for publicKey: String, using dependencies: Dependencies) -> PollerErrorResponse {
        if UserDefaults.sharedLokiProject?[.isMainAppActive] != true {
            // Do nothing when an error gets throws right after returning from the background (happens frequently)
        }
        else if
            let drainBehaviour: ThreadSafeObject<SwarmDrainBehaviour> = drainBehaviour[publicKey],
            case .limitedReuse(_, .some(let targetSnode), _, _, _) = drainBehaviour.wrappedValue
        {
            drainBehaviour.set(to: drainBehaviour.wrappedValue.clearTargetSnode())
            return .continuePollingInfo("Switching from \(targetSnode) to next snode.")
        }
        else {
            return .continuePollingInfo("Had no target snode.")
        }
        
        return .continuePolling
    }
}
