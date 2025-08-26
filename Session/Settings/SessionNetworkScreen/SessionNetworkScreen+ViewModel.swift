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
        @Published public var state: State
        @Published public var isRefreshing: Bool = false
        @Published public var lastRefreshWasSuccessful: Bool = false
        @Published public var errorString: String? = nil
        @Published public var lastUpdatedTimeString: String? = nil
        
        private let dependencies: Dependencies
        private var observationTask: Task<Void, Never>?
        private var getInfoTask: Task<Void, Never>?
        
        private var timer: Timer? = nil
        
        public struct ObservableState: ObservableKeyProvider {
            public let state: State
            
            public var observedKeys: Set<ObservableKey> = [
                .keyValue(.contractAddress),
                .keyValue(.tokenUsd),
                .keyValue(.priceTimestampMs),
                .keyValue(.stakingRequirement),
                .keyValue(.networkSize),
                .keyValue(.networkStakedUSD),
                .keyValue(.stakingRewardPool),
                .keyValue(.marketCapUsd),
                .keyValue(.lastUpdatedTimestampMs),
                .conversationCreated,
                .anyConversationDeleted
            ]
        }
        
        
        init(dependencies: Dependencies) {
            self.dependencies = dependencies
            self.state = State(
                snodesInCurrentSwarm: 0,
                snodesInTotal: 0,
                contractAddress: nil,
                tokenUSD: nil,
                priceTimestampMs: 0,
                stakingRequirement: 0,
                networkSize: 0,
                networkStakedTokens: 0,
                networkStakedUSD: 0,
                stakingRewardPool: nil,
                marketCapUSD: nil,
                totalTargetConversations: 0,
                lastUpdatedTimestampMs: nil
            )
            
            self.observationTask = ObservationBuilder
                .initialValue(ObservableState(state: state))
                .debounce(for: .milliseconds(250))
                .using(dependencies: dependencies)
                .query(ViewModel.queryState)
                .assign { [weak self] updatedState in
                    self?.state = updatedState.state
                    self?.updateLastUpdatedTimeString()
                }
        }
        
        deinit {
            getInfoTask?.cancel()
            observationTask?.cancel()
        }
        
        @Sendable private static func queryState(
            previousState: ObservableState,
            events: [ObservedEvent],
            isInitialQuery: Bool,
            using dependencies: Dependencies
        ) async -> ObservableState {
            var contractAddress: String? = previousState.state.contractAddress
            var tokenUSD: Double? = previousState.state.tokenUSD
            var priceTimestampMs: Int64 = previousState.state.priceTimestampMs
            var stakingRequirement: Double = previousState.state.stakingRequirement
            var networkSize: Int = previousState.state.networkSize
            var networkStakedTokens: Double = previousState.state.networkStakedTokens
            var networkStakedUSD: Double = previousState.state.networkStakedUSD
            var stakingRewardPool: Double? = previousState.state.stakingRewardPool
            var marketCapUSD: Double? = previousState.state.marketCapUSD
            var lastUpdatedTimestampMs: Int64? = previousState.state.lastUpdatedTimestampMs
            var totalTargetConversations: Int = previousState.state.totalTargetConversations
            let validThreadVariants: [SessionThread.Variant] = [.contact, .group, .legacyGroup]
            
            /// On the first query we want to load the state from the database
            if isInitialQuery {
                try? await dependencies[singleton: .storage].readAsync { db in
                    contractAddress = (db[.contractAddress] ?? contractAddress)
                    tokenUSD = (db[.tokenUsd] ?? tokenUSD)
                    priceTimestampMs = (db[.priceTimestampMs] ?? priceTimestampMs)
                    stakingRequirement = (db[.stakingRequirement] ?? stakingRequirement)
                    networkSize = (db[.networkSize] ?? networkSize)
                    networkStakedTokens = (db[.networkStakedTokens] ?? networkStakedTokens)
                    networkStakedUSD = (db[.networkStakedUSD] ?? networkStakedUSD)
                    stakingRewardPool = (db[.stakingRewardPool] ?? stakingRewardPool)
                    marketCapUSD = (db[.marketCapUsd] ?? marketCapUSD)
                    lastUpdatedTimestampMs = (db[.lastUpdatedTimestampMs] ?? lastUpdatedTimestampMs)
                    
                    totalTargetConversations = (try? SessionThread
                        .filter(validThreadVariants.contains(SessionThread.Columns.variant))
                        .fetchCount(db))
                        .defaulting(to: 0)
                }
            }

            /// Re-fetch the total conversation count if needed
            if events.contains(where: { $0.key == .conversationCreated || $0.key == .anyConversationDeleted }) {
                try? await dependencies[singleton: .storage].readAsync { db in
                    totalTargetConversations = (try? SessionThread
                        .filter(validThreadVariants.contains(SessionThread.Columns.variant))
                        .fetchCount(db))
                        .defaulting(to: 0)
                }
            }
            
            /// Extract data changes from events
            events.forEach { event in
                switch (event.key, event.value) {
                    case (.keyValue(.contractAddress), let value as String): contractAddress = value
                    case (.keyValue(.tokenUsd), let value as Double): tokenUSD = value
                    case (.keyValue(.priceTimestampMs), let value as Int64): priceTimestampMs = value
                    case (.keyValue(.stakingRequirement), let value as Double): stakingRequirement = value
                    case (.keyValue(.networkSize), let value as Int): networkSize = value
                    case (.keyValue(.networkStakedTokens), let value as Double): networkStakedTokens = value
                    case (.keyValue(.networkStakedUSD), let value as Double): networkStakedUSD = value
                    case (.keyValue(.networkStakedTokens), let value as Double): networkStakedTokens = value
                    case (.keyValue(.stakingRewardPool), let value as Double?): stakingRewardPool = value
                    case (.keyValue(.marketCapUsd), let value as Double?): marketCapUSD = value
                    case (.keyValue(.lastUpdatedTimestampMs), let value as Int64?): lastUpdatedTimestampMs = value
                    case (.conversationCreated, _), (.anyConversationDeleted, _): break
                    default:
                        Log.warn("[SessionNetworkScreen] Received update event with unknown key: \(event.key)")
                        break
                }
            }
            
            /// Retrieve the latest state from the network
            let userSessionId: SessionId = dependencies[cache: .general].sessionId
            let snodesInCurrentSwarm: Int = ((try? await dependencies[singleton: .network]
                .getSwarm(for: userSessionId.hexString)
                .count) ?? 0)
            let pathsCount: Int = ((try? await dependencies[singleton: .network].getActivePaths().count) ?? 0)
            let calculatedSnodeInTotal: Int = (snodesInCurrentSwarm + pathsCount * 3 + totalTargetConversations * 6)
            let snodesInTotal: Int = min(networkSize, calculatedSnodeInTotal)
            
            return ObservableState(
                state: State(
                    snodesInCurrentSwarm: snodesInCurrentSwarm,
                    snodesInTotal: snodesInTotal,
                    contractAddress: contractAddress,
                    tokenUSD: tokenUSD,
                    priceTimestampMs: priceTimestampMs,
                    stakingRequirement: stakingRequirement,
                    networkSize: networkSize,
                    networkStakedTokens: networkStakedTokens,
                    networkStakedUSD: networkStakedUSD,
                    stakingRewardPool: stakingRewardPool,
                    marketCapUSD: marketCapUSD,
                    totalTargetConversations: totalTargetConversations,
                    lastUpdatedTimestampMs: lastUpdatedTimestampMs
                )
            )
        }
        
        public func fetchDataFromNetwork() {
            guard !self.isRefreshing else { return }
            
            self.isRefreshing.toggle()
            self.lastRefreshWasSuccessful = false
            
            getInfoTask = Task { [weak self, client = dependencies[singleton: .sessionNetworkApiClient]] in
                do {
                    _ = try await client.getInfo()
                    await MainActor.run { [weak self] in
                        self?.lastRefreshWasSuccessful = true
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        self?.lastRefreshWasSuccessful = false
                    }
                }
                
                self?.isRefreshing.toggle()
            }
        }
        
        public func openURL(_ url: URL) {
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
        
        private func updateLastUpdatedTimeString() {
            self.lastUpdatedTimeString = {
                guard let lastUpdatedTimestampMs = state.lastUpdatedTimestampMs else { return nil }
                return String.formattedRelativeTime(
                    lastUpdatedTimestampMs,
                    minimumUnit: .minute
                )
            }()
            self.timer?.invalidate()
            self.timer = Timer.scheduledTimerOnMainThread(withTimeInterval: 60, repeats: true, using: dependencies) { [weak self] _ in
                self?.lastUpdatedTimeString = {
                    guard let lastUpdatedTimestampMs = self?.state.lastUpdatedTimestampMs else { return nil }
                    return String.formattedRelativeTime(
                        lastUpdatedTimestampMs,
                        minimumUnit: .minute
                    )
                }()
            }
        }
    }
}
