// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit

public extension Singleton {
    static let sessionNetworkApiClient: SingletonConfig<Network.SessionNetwork.HTTPClient> = Dependencies.create(
        identifier: "sessionNetworkApiClient",
        createInstance: { dependencies, _ in Network.SessionNetwork.HTTPClient(using: dependencies) }
    )
}

// MARK: - Log.Category

public extension Log.Category {
    static let sessionNetwork: Log.Category = .create("SessionNetwork", defaultLevel: .info)
}

public extension Network.SessionNetwork {
    final class HTTPClient {
        private var getInfoTask: Task<Void, Never>?
        private var dependencies: Dependencies
        
        public init(using dependencies: Dependencies) {
            self.dependencies = dependencies
        }
        
        public func fetchInfoInBackground() {
            getInfoTask = Task {
                _ = try? await getInfo()
            }
        }
        
        public func getInfo() async throws -> Bool {
            getInfoTask?.cancel()
            
            let staleTimestampMs: Int64 = (try? await dependencies[singleton: .storage]
                .readAsync { db in db[.staleTimestampMs] })
                .defaulting(to: 0)
            
            guard staleTimestampMs < dependencies[cache: .snodeAPI].currentOffsetTimestampMs() else {
                try? await Task.sleep(for: .milliseconds(500))
                try await dependencies[singleton: .storage].writeAsync { [dependencies] db in
                    db[.lastUpdatedTimestampMs] = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                }
                
                return true
            }
            
            do {
                let info: Network.SessionNetwork.Info = try await Network.SessionNetwork
                    .prepareInfo(using: dependencies)
                    .send(using: dependencies)
                
                try await dependencies[singleton: .storage].writeAsync { [dependencies] db in
                    // Token info
                    db[.lastUpdatedTimestampMs] = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                    db[.tokenUsd] = info.price?.tokenUsd
                    db[.marketCapUsd] = info.price?.marketCapUsd
                    if let priceTimestamp = info.price?.priceTimestamp {
                        db[.priceTimestampMs] = priceTimestamp * 1000
                    } else {
                        db[.priceTimestampMs] = nil
                    }
                    if let staleTimestamp = info.price?.staleTimestamp {
                        db[.staleTimestampMs] = staleTimestamp * 1000
                    } else {
                        db[.staleTimestampMs] = nil
                    }
                    db[.stakingRequirement] = info.token?.stakingRequirement
                    db[.stakingRewardPool] = info.token?.stakingRewardPool
                    db[.contractAddress] = info.token?.contractAddress
                    // Network info
                    db[.networkSize] = info.network?.networkSize
                    db[.networkStakedTokens] = info.network?.networkStakedTokens
                    db[.networkStakedUSD] = info.network?.networkStakedUSD
                }
                
                return true
            }
            catch {
                Log.error(.sessionNetwork, "Failed to fetch token info due to error: \(error).")
                try? await cleanUpSessionNetworkPageData()
                return false
            }
        }
        
        private func cleanUpSessionNetworkPageData() async throws {
            try await dependencies[singleton: .storage].writeAsync { db in
                // Token info
                db[.lastUpdatedTimestampMs] = nil
                db[.tokenUsd] = nil
                db[.marketCapUsd] = nil
                db[.priceTimestampMs] = nil
                db[.staleTimestampMs] = nil
                db[.stakingRequirement] = nil
                db[.stakingRewardPool] = nil
                db[.contractAddress] = nil
                // Network info
                db[.networkSize] = nil
                db[.networkStakedTokens] = nil
                db[.networkStakedUSD] = nil
            }
        }
    }
}
