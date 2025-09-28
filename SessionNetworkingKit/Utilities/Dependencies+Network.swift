// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension Dependencies {
    var networkStatusUpdates: AsyncStream<NetworkStatus> {
        if #available(iOS 16.0, *) {
            self.stream(singleton: .network).switchMap { $0.networkStatus }
        }
        else {
            self[singleton: .network].networkStatus
        }
    }
    
    var currentNetworkStatus: NetworkStatus {
        get async { await networkStatusUpdates.first(defaultValue: .unknown) }
    }
    
    nonisolated func networkOffsetTimestampMs<T: Numeric>() -> T {
        return timestampNowMsWithOffset(
            offsetMs: self[singleton: .network].syncState.networkTimeOffsetMs
        )
    }
    
    func networkOffsetTimestampMs<T: Numeric>() async -> T {
        return await timestampNowMsWithOffset(
            offsetMs: self[singleton: .network].networkTimeOffsetMs
        )
    }
    
    /// Asynchronously waits until the network status is `connected`.
    ///
    /// **Note:** Since this observes the `networkStatusUpdates` it handles cases where the `network` instance is replaced
    /// (eg. switching from Onion Requests to Lokinet) and will continue waiting until the *new* network instance reports a connected status.
    func waitUntilConnected(onWillStartWaiting: (() async -> Void)? = nil) async throws {
        /// Get the current `networkStatus`, if we are already connected then we can just stop immediately
        guard await currentNetworkStatus != .connected else { return }
        
        /// If we need to wait then inform the caller just in case they need to do something first
        await onWillStartWaiting?()
        
        /// Wait for the a `network` instance to report a `connected` status
        _ = await networkStatusUpdates.first(where: { $0 == .connected })
        
        if #unavailable(iOS 16.0) {
            throw NetworkError.invalidState
        }
    }
}
