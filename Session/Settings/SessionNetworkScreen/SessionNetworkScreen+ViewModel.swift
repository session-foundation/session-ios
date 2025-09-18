// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SwiftUI
import Combine
import GRDB
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit
import SessionMessagingKit

extension SessionNetworkScreenContent {
    public class ViewModel: ObservableObject, ViewModelType {
        @Published public var dataModel: DataModel
        @Published public var isRefreshing: Bool = false
        @Published public var lastRefreshWasSuccessful: Bool = false
        @Published public var errorString: String? = nil
        @Published public var lastUpdatedTimeString: String? = nil
        
        private var observationCancellable: AnyCancellable?
        private var dependencies: Dependencies
        
        private var disposables = Set<AnyCancellable>()
        
        private var timer: Timer? = nil
        
        init(dependencies: Dependencies) {
            self.dependencies = dependencies
            self.dataModel = DataModel()
            
            let userSessionId: SessionId = dependencies[cache: .general].sessionId
            self.observationCancellable = ObservationBuilderOld
                .databaseObservation(dependencies) { [dependencies] db in
                    let swarmNodesCount: Int = dependencies[cache: .libSessionNetwork].snodeNumber[userSessionId.hexString] ?? 0
                    let snodeInTotal: Int = {
                        let pathsCount: Int = dependencies[cache: .libSessionNetwork].currentPaths.count
                        let validThreadVariants: [SessionThread.Variant] = [.contact, .group, .legacyGroup]
                        let convosInTotal: Int = (
                            try? SessionThread
                                .filter(validThreadVariants.contains(SessionThread.Columns.variant))
                                .fetchAll(db)
                        )
                        .defaulting(to: [])
                        .count
                        let calculatedSnodeInTotal = swarmNodesCount + pathsCount * 3 + convosInTotal * 6
                        if let networkSize = db[.networkSize] {
                            return min(networkSize, calculatedSnodeInTotal)
                        }
                        return calculatedSnodeInTotal
                    }()
                    
                    return DataModel(
                        snodesInCurrentSwarm: swarmNodesCount,
                        snodesInTotal: snodeInTotal,
                        contractAddress: db[.contractAddress],
                        tokenUSD: db[.tokenUsd],
                        priceTimestampMs: db[.priceTimestampMs] ?? 0,
                        stakingRequirement: db[.stakingRequirement] ?? 0,
                        networkSize: db[.networkSize] ?? 0,
                        networkStakedTokens: db[.networkStakedTokens] ?? 0,
                        networkStakedUSD: db[.networkStakedUSD] ?? 0,
                        stakingRewardPool: db[.stakingRewardPool],
                        marketCapUSD: db[.marketCapUsd],
                        lastUpdatedTimestampMs: db[.lastUpdatedTimestampMs]
                    )
                }
                .sink(
                    receiveCompletion: { _ in /* ignore error */ },
                    receiveValue: { [weak self] dataModel in
                        self?.dataModel = dataModel
                        self?.updateLastUpdatedTimeString()
                    }
                )
        }
        
        public func fetchDataFromNetwork() {
            guard !self.isRefreshing else { return }
            self.isRefreshing.toggle()
            self.lastRefreshWasSuccessful = false
            
            Network.SessionNetwork.client.getInfo(using: dependencies)
                .subscribe(on: Network.SessionNetwork.workQueue, using: dependencies)
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { _ in },
                    receiveValue: { [weak self] didRefreshSuccessfully in
                        self?.lastRefreshWasSuccessful = didRefreshSuccessfully
                        self?.isRefreshing.toggle()
                    }
                )
                .store(in: &disposables)
        }
        
        public func openURL(_ url: URL) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        
        private func updateLastUpdatedTimeString() {
            self.lastUpdatedTimeString = {
                guard let lastUpdatedTimestampMs = dataModel.lastUpdatedTimestampMs else { return nil }
                return String.formattedRelativeTime(
                    lastUpdatedTimestampMs,
                    minimumUnit: .minute
                )
            }()
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimerOnMainThread(withTimeInterval: 60, repeats: true, using: dependencies) { [weak self] _ in
                self?.lastUpdatedTimeString = {
                    guard let lastUpdatedTimestampMs = self?.dataModel.lastUpdatedTimestampMs else { return nil }
                    return String.formattedRelativeTime(
                        lastUpdatedTimestampMs,
                        minimumUnit: .minute
                    )
                }()
            }
        }
    }
}
