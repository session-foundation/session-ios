// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import PromiseKit
import SessionSnodeKit
import SessionUtilitiesKit

public final class CurrentUserPoller: Poller {
    public static var namespaces: [SnodeAPI.Namespace] = [.default, .userProfileConfig]
    
    private var targetSnode: Atomic<Snode?> = Atomic(nil)
    private var usedSnodes: Atomic<Set<Snode>> = Atomic([])

    // MARK: - Settings
    
    override var namespaces: [SnodeAPI.Namespace] { CurrentUserPoller.namespaces }
    
    /// After polling a given snode this many times we always switch to a new one.
    ///
    /// The reason for doing this is that sometimes a snode will be giving us successful responses while
    /// it isn't actually getting messages from other snodes.
    override var maxNodePollCount: UInt { 6 }
    
    private let pollInterval: TimeInterval = 1.5
    private let retryInterval: TimeInterval = 0.25
    private let maxRetryInterval: TimeInterval = 15
    
    // MARK: - Convenience Functions
    
    public func start() {
        let publicKey: String = getUserHexEncodedPublicKey()
        
        guard isPolling.wrappedValue[publicKey] != true else { return }
        
        SNLog("Started polling.")
        super.startIfNeeded(for: publicKey)
    }
    
    public func stop() {
        SNLog("Stopped polling.")
        super.stopAllPollers()
    }
    
    // MARK: - Abstract Methods
    
    override func pollerName(for publicKey: String) -> String {
        return "Main Poller"
    }
    
    override func nextPollDelay(for publicKey: String) -> TimeInterval {
        let failureCount: TimeInterval = TimeInterval(failureCount.wrappedValue[publicKey] ?? 0)
        
        // If there have been no failures then just use the 'minPollInterval'
        guard failureCount > 0 else { return pollInterval }
        
        // Otherwise use a simple back-off with the 'retryInterval'
        let nextDelay: TimeInterval = (retryInterval * (failureCount * 1.2))
                                       
        return min(maxRetryInterval, nextDelay)
    }
    
    override func getSnodeForPolling(
        for publicKey: String,
        on queue: DispatchQueue
    ) -> Promise<Snode> {
        if let targetSnode: Snode = self.targetSnode.wrappedValue {
            return Promise.value(targetSnode)
        }
        
        // Used the cached swarm for the given key and update the list of unusedSnodes
        let swarm: Set<Snode> = (SnodeAPI.swarmCache.wrappedValue[publicKey] ?? [])
        let unusedSnodes: Set<Snode> = swarm.subtracting(usedSnodes.wrappedValue)
        
        // randomElement() uses the system's default random generator, which is cryptographically secure
        if let nextSnode: Snode = unusedSnodes.randomElement() {
            self.targetSnode.mutate { $0 = nextSnode }
            self.usedSnodes.mutate { $0.insert(nextSnode) }
            
            return Promise.value(nextSnode)
        }
        
        // If we haven't retrieved a target snode at this point then either the cache
        // is empty or we have used all of the snodes and need to start from scratch
        return SnodeAPI.getSwarm(for: publicKey)
            .then(on: queue) { [weak self] _ -> Promise<Snode> in
                guard let strongSelf = self else { return Promise(error: SnodeAPIError.generic) }
                
                self?.targetSnode.mutate { $0 = nil }
                self?.usedSnodes.mutate { $0.removeAll() }
                
                return strongSelf.getSnodeForPolling(for: publicKey, on: queue)
            }
    }
    
    override func handlePollError(_ error: Error, for publicKey: String) {
        if UserDefaults.sharedLokiProject?[.isMainAppActive] != true {
            // Do nothing when an error gets throws right after returning from the background (happens frequently)
        }
        else if let targetSnode: Snode = targetSnode.wrappedValue {
            SNLog("Polling \(targetSnode) failed; dropping it and switching to next snode.")
            self.targetSnode.mutate { $0 = nil }
            SnodeAPI.dropSnodeFromSwarmIfNeeded(targetSnode, publicKey: publicKey)
        }
        else {
            SNLog("Polling failed due to having no target service node.")
        }
        
        // Try to restart the poller from scratch
        Threading.pollerQueue.async { [weak self] in
            self?.setUpPolling(for: publicKey)
        }
    }
}
