// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit

// MARK: - Log.Category

public extension Log.Category {
    static let sessionNetwork: Log.Category = .create("SessionNetwork", defaultLevel: .info)
}

extension SessionNetworkAPI {
    public final class HTTPClient {
        private var cancellable: AnyCancellable?
        private var dependencies: Dependencies?
        
        public func initialize(using dependencies: Dependencies) {
            self.dependencies = dependencies
            cancellable = getInfo(using: dependencies)
                .subscribe(on: Threading.workQueue, using: dependencies)
                .receive(on: SessionNetworkAPI.workQueue)
                .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
        }
        
        public func getInfo(using dependencies: Dependencies) -> AnyPublisher<Bool, Error> {
            cancellable?.cancel()
            
            let staleTimestampMs: Int64 = dependencies[singleton: .storage].read { db in db[.staleTimestampMs] }.defaulting(to: 0)
            guard staleTimestampMs < dependencies[cache: .snodeAPI].currentOffsetTimestampMs() else {
                return Just(())
                    .delay(for: .milliseconds(500), scheduler: Threading.workQueue)
                    .setFailureType(to: Error.self)
                    .flatMapStorageWritePublisher(using: dependencies) { [dependencies] db, info -> Bool in
                        db[.lastUpdatedTimestampMs] = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                        return true
                    }
                    .eraseToAnyPublisher()
            }
            
            return Result {
                try SessionNetworkAPI
                    .prepareInfo(using: dependencies)
                }
                .publisher
                .flatMap { [dependencies] in $0.send(using: dependencies) }
                .map { _, info in info }
                .flatMapStorageWritePublisher(using: dependencies) { [dependencies] db, info -> Bool in
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
                    
                    return true
                }
                .catch { error -> AnyPublisher<Bool, Error> in
                    Log.error(.sessionNetwork, "Failed to fetch token info due to error: \(error).")
                    return self.cleanUpSessionNetworkPageData(using: dependencies)
                        .map { _ in false }
                        .eraseToAnyPublisher()
                    
                }
                .eraseToAnyPublisher()
        }
        
        private func cleanUpSessionNetworkPageData(using dependencies: Dependencies) -> AnyPublisher<Void, Error> {
            dependencies[singleton: .storage].writePublisher { db in
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
