// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let currentUserPoller: SingletonConfig<any PollerType> = Dependencies.create(
        identifier: "currentUserPoller",
        createInstance: { dependencies, key in
            /// After polling a given snode 6 times we always switch to a new one.
            ///
            /// The reason for doing this is that sometimes a snode will be giving us successful responses while
            /// it isn't actually getting messages from other snodes.
            return CurrentUserPoller(
                pollerName: "Main Poller", // stringlint:ignore
                pollerQueue: Threading.pollerQueue,
                pollerDestination: .swarm(dependencies[cache: .general].sessionId.hexString),
                swarmDrainStrategy: .limitedReuse(count: 6),
                namespaces: CurrentUserPoller.namespaces,
                shouldStoreMessages: true,
                logStartAndStopCalls: true,
                key: key,
                using: dependencies
            )
        }
    )
}

// MARK: - CurrentUserPoller

public final class CurrentUserPoller: SwarmPoller {
    public static let namespaces: [Network.SnodeAPI.Namespace] = [
        .default, .configUserProfile, .configContacts, .configConvoInfoVolatile, .configUserGroups
    ]
    private let pollInterval: TimeInterval = 1.5
    private let retryInterval: TimeInterval = 0.25
    private let maxRetryInterval: TimeInterval = 15
    
    // MARK: - Abstract Methods
    
    override public func nextPollDelay() async -> TimeInterval {
        // If there have been no failures then just use the 'minPollInterval'
        guard failureCount > 0 else { return pollInterval }
        
        // Otherwise use a simple back-off with the 'retryInterval'
        let nextDelay: TimeInterval = TimeInterval(retryInterval * (Double(failureCount) * 1.2))
        
        return min(maxRetryInterval, nextDelay)
    }
}
