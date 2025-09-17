// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension Dependencies {
    var currentNetworkStatus: NetworkStatus {
        get async { await networkStatusUpdates.first(defaultValue: .unknown) }
    }
    
    var networkStatusUpdates: AsyncStream<NetworkStatus> {
        return AsyncStream { continuation in
            let observationTask: Task<Void, Never> = Task {
                var innerTask: Task<Void, Never>?
                
                for await network in self.stream(singleton: .network) {
                    innerTask?.cancel()
                    innerTask = Task {
                        for await status in network.networkStatus {
                            let result = continuation.yield(status)
                            
                            switch result {
                                case .terminated: return
                                default: break
                            }
                        }
                    }
                }
            }
            
            continuation.onTermination = { @Sendable _ in
                observationTask.cancel()
            }
        }
    }
    
    /// Asynchronously waits until the network status is `connected`.
    ///
    /// If the `network` instance is replaced (eg. switching from Onion Requests to Lokinet) then simply observing the `networkStatus`
    /// stream would result in the code just continuing (since the stream finishes). This would almost always result in the subsequent
    /// code failing (since the new instance is unlikely to connect in time for the code to send a successful request. As such this function
    /// will handle such changes and continue waiting for the *new* network instance to report a connected status.
    func waitUntilConnected(
        onWillStartWaiting: (() async -> Void)? = nil,
        retryDelayProvider: @escaping () async throws -> TimeInterval = { 1.0 }
    ) async throws {
        /// Get the current `networkStatus`, if we are already connected then we can just stop immediately
        guard await currentNetworkStatus != .connected else { return }
        
        /// If we need to wait then inform the caller just in case they need to do something first
        await onWillStartWaiting?()
        
        while true {
            try Task.checkCancellation()
            
            /// Wait for the latest `network` instance to report a `connected` status
            guard await networkStatusUpdates.first(where: { $0 == .connected }) == nil else {
                return
            }
            
            /// If we still aren't connected then it means the stream was terminated (likely the `network` instance was replaced), in
            /// that case we want to continue waiting until the *new* instance gets connected
            ///
            /// **Note:** We add a small delay before looping to safeguard against tight "busy-wait" loops
            let delay: Int = Int(floor(try await retryDelayProvider()))
            try await Task.sleep(for: .seconds(delay))
        }
    }
}
