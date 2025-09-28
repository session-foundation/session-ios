// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum SessionNetworkScreenContent {}

public extension SessionNetworkScreenContent {
    static let defaultPriceString: String = "$-USD" // stringlint:disabled
    
    protocol ViewModelType: ObservableObject {
        var state: State { get set }
        var isRefreshing: Bool { get set }
        var lastRefreshWasSuccessful: Bool { get set }
        var errorString: String? { get set }
        var lastUpdatedTimeString: String? { get set }
        
        func fetchDataFromNetwork()
        func openURL(_ url: URL)
    }
    
    final class State: Sendable, Equatable {
        // Snode Data
        public let snodesInCurrentSwarm: Int
        public let snodesInTotal: Int
        public var snodesInTotalString: String { "\(snodesInTotal)" }
        public var snodesInTotalAbbreviatedString: String {
            "\(snodesInTotal.formatted(format: .abbreviated(decimalPlaces: 1)))"
        }
        public var snodesInTotalAbbreviatedNoDecimalString: String {
            "\(snodesInTotal.formatted(format: .abbreviated))"
        }
        
        // Toke Info Data
        public let contractAddress: String?
        public let tokenUSD: Double?
        public var tokenUSDString: String {
            guard let tokenUSD: Double = tokenUSD else {
                return "unavailable".localized()
            }
            return "$\(tokenUSD.formatted(format: .currency(decimal: true))) USD"
        }
        public var tokenUSDNoCentsString: String {
            guard let tokenUSD: Double = tokenUSD else {
                return "unavailable".localized()
            }
            return "$\(tokenUSD.formatted(format: .currency(decimal: false))) USD"
        }
        public var tokenUSDAbbreviatedString: String {
            guard let tokenUSD: Double = tokenUSD else {
                return "unavailable".localized()
            }
            return "$\(tokenUSD.formatted(format: .abbreviatedCurrency(decimalPlaces: 1))) USD"
        }
        public let priceTimestampMs: Int64
        public var priceTimeString: String {
            guard tokenUSD != nil else {
                return "-"
            }
            return Date(timeIntervalSince1970: (TimeInterval(priceTimestampMs) / 1000)).formatted("d MMM YYYY hh:mm a")
        }
        public let stakingRequirement: Double
        public let networkSize: Int
        public let networkStakedTokens: Double
        public var networkStakedTokensString: String {
            guard networkStakedTokens > 0 else {
                return "unavailable".localized()
            }
            return "\(networkStakedTokens.formatted(format: .abbreviated)) \(Constants.token_name_short)"
        }
        public let networkStakedUSD: Double
        public var networkStakedUSDString: String {
            guard networkStakedUSD > 0 else { return defaultPriceString }
            
            return "$\(networkStakedUSD.formatted(format: .currency(decimal: false))) USD"
        }
        public var networkStakedUSDAbbreviatedString: String {
            guard networkStakedUSD > 0 else { return defaultPriceString }
            
            return "$\(networkStakedUSD.formatted(format: .abbreviatedCurrency(decimalPlaces: 1))) USD"
        }
        public let stakingRewardPool: Double?
        public var stakingRewardPoolString: String {
            guard let stakingRewardPool: Double = stakingRewardPool else {
                return "unavailable".localized()
            }
            return "\(stakingRewardPool.formatted(format: .decimal)) \(Constants.token_name_short)"
        }
        public let marketCapUSD: Double?
        public var marketCapString: String {
            guard let marketCap: Double = marketCapUSD else {
                return "unavailable".localized()
            }
            return "$\(marketCap.formatted(format: .currency(decimal: false))) USD"
        }
        public var marketCapAbbreviatedString: String {
            guard let marketCap: Double = marketCapUSD else {
                return "unavailable".localized()
            }
            return "$\(marketCap.formatted(format: .abbreviatedCurrency(decimalPlaces: 1))) USD"
        }
        public let totalTargetConversations: Int
        
        // Last update time
        public let lastUpdatedTimestampMs: Int64?
        
        // MARK: - Initialization
        
        public init(
            snodesInCurrentSwarm: Int,
            snodesInTotal: Int,
            contractAddress: String?,
            tokenUSD: Double?,
            priceTimestampMs: Int64,
            stakingRequirement: Double,
            networkSize: Int,
            networkStakedTokens: Double,
            networkStakedUSD: Double,
            stakingRewardPool: Double?,
            marketCapUSD: Double?,
            totalTargetConversations: Int,
            lastUpdatedTimestampMs: Int64?
        ) {
            self.snodesInCurrentSwarm = snodesInCurrentSwarm
            self.snodesInTotal = snodesInTotal
            self.contractAddress = contractAddress
            self.tokenUSD = tokenUSD
            self.priceTimestampMs = priceTimestampMs
            self.stakingRequirement = stakingRequirement
            self.networkSize = networkSize
            self.networkStakedTokens = networkStakedTokens
            self.networkStakedUSD = networkStakedUSD
            self.stakingRewardPool = stakingRewardPool
            self.marketCapUSD = marketCapUSD
            self.totalTargetConversations = totalTargetConversations
            self.lastUpdatedTimestampMs = lastUpdatedTimestampMs
        }
        
        public static func == (lhs: State, rhs: State) -> Bool {
            let isSnodeInfoEqual: Bool = (
                lhs.snodesInCurrentSwarm == rhs.snodesInCurrentSwarm &&
                lhs.snodesInTotal == rhs.snodesInTotal
            )
            
            let isTokenInfoDataEqual: Bool = (
                lhs.contractAddress == rhs.contractAddress &&
                lhs.tokenUSD == rhs.tokenUSD &&
                lhs.priceTimestampMs == rhs.priceTimestampMs &&
                lhs.stakingRequirement == rhs.stakingRequirement
            )
            
            let isNetworkInfoDataEqual: Bool = (
                lhs.networkSize == rhs.networkSize &&
                lhs.networkStakedTokens == rhs.networkStakedTokens &&
                lhs.networkStakedUSD == rhs.networkStakedUSD &&
                lhs.stakingRewardPool == rhs.stakingRewardPool &&
                lhs.marketCapUSD == rhs.marketCapUSD
            )
            
            let convoCountEqual: Bool = lhs.totalTargetConversations == rhs.totalTargetConversations
            let isUpdateTimeEqual: Bool = lhs.lastUpdatedTimestampMs == rhs.lastUpdatedTimestampMs
                
            return (
                isSnodeInfoEqual &&
                isTokenInfoDataEqual &&
                isNetworkInfoDataEqual &&
                convoCountEqual &&
                isUpdateTimeEqual
            )
        }
    }
}

// MARK: - Convenience

extension SessionNetworkScreenContent.State {
    public func with(
        snodesInCurrentSwarm: Int? = nil,
        snodesInTotal: Int? = nil,
        contractAddress: String? = nil,
        tokenUSD: Double? = nil,
        priceTimestampMs: Int64? = nil,
        stakingRequirement: Double? = nil,
        networkSize: Int? = nil,
        networkStakedTokens: Double? = nil,
        networkStakedUSD: Double? = nil,
        stakingRewardPool: Double? = nil,
        marketCapUSD: Double? = nil,
        totalTargetConversations: Int? = nil,
        lastUpdatedTimestampMs: Int64? = nil
    ) -> SessionNetworkScreenContent.State {
        return SessionNetworkScreenContent.State(
            snodesInCurrentSwarm: snodesInCurrentSwarm ?? self.snodesInCurrentSwarm,
            snodesInTotal: snodesInTotal ?? self.snodesInTotal,
            contractAddress: contractAddress ?? self.contractAddress,
            tokenUSD: tokenUSD ?? self.tokenUSD,
            priceTimestampMs: priceTimestampMs ?? self.priceTimestampMs,
            stakingRequirement: stakingRequirement ?? self.stakingRequirement,
            networkSize: networkSize ?? self.networkSize,
            networkStakedTokens: networkStakedTokens ?? self.networkStakedTokens,
            networkStakedUSD: networkStakedUSD ?? self.networkStakedUSD,
            stakingRewardPool: stakingRewardPool ?? self.stakingRewardPool,
            marketCapUSD: marketCapUSD ?? self.marketCapUSD,
            totalTargetConversations: totalTargetConversations ?? self.totalTargetConversations,
            lastUpdatedTimestampMs: lastUpdatedTimestampMs ?? self.lastUpdatedTimestampMs
        )
    }
}
