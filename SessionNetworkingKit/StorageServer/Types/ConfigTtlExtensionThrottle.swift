// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let configTtlExtensionThrottle: SingletonConfig<Network.StorageServer.ConfigTtlExtensionThrottle> = Dependencies.create(
        identifier: "configTtlExtensionThrottle",
        createInstance: { dependencies, _ in Network.StorageServer.ConfigTtlExtensionThrottle(using: dependencies) }
    )
}

// MARK: - ConfigTtlExtensionThrottle

public extension Network.StorageServer {
    /// Limits how often a poll asks the swarm to extend the TTL of our config messages
    ///
    /// Every extension is a write on every storage node holding those messages, and polls run every few seconds, so extending on
    /// each poll puts real disk I/O load on service nodes for no benefit: the extension is to 30 days from now, so doing it once an
    /// hour loses nothing
    ///
    /// Tracked per swarm, so one group's renewal never suppresses another group's or the user's own
    actor ConfigTtlExtensionThrottle {
        public static let cooldown: TimeInterval = (60 * 60)

        private let dependencies: Dependencies
        private var lastSuccessfulExtension: [String: Date] = [:]

        init(using dependencies: Dependencies) {
            self.dependencies = dependencies
        }

        public func isDue(swarmPublicKey: String) -> Bool {
            guard let last: Date = lastSuccessfulExtension[swarmPublicKey] else { return true }

            let elapsed: TimeInterval = dependencies.dateNow.timeIntervalSince(last)

            /// A negative value means the device clock was moved backwards, without this check that could hold the cooldown open
            /// for however far the clock moved and let the configs age out
            return (elapsed < 0 || elapsed >= ConfigTtlExtensionThrottle.cooldown)
        }

        /// Must only be called once the storage server has confirmed the extension, a failed extension that started the cooldown
        /// would leave the configs un-renewed while looking handled, and repeated failures would let them age out of the swarm
        public func recordSuccessfulExtension(swarmPublicKey: String) {
            lastSuccessfulExtension[swarmPublicKey] = dependencies.dateNow
        }
    }
}
