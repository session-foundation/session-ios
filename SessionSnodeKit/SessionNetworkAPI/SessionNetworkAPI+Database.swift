// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import AudioToolbox
import GRDB
import DifferenceKit
import SessionUtilitiesKit

public extension KeyValueStore.StringKey {
    static let contractAddress: KeyValueStore.StringKey = "contractAddress"
}

public extension KeyValueStore.DoubleKey {
    static let tokenUsd: KeyValueStore.DoubleKey = "tokenUsd"
    static let marketCapUsd: KeyValueStore.DoubleKey = "marketCapUsd"
    static let stakingRequirement: KeyValueStore.DoubleKey = "stakingRequirement"
    static let stakingRewardPool: KeyValueStore.DoubleKey = "stakingRewardPool"
    static let networkStakedTokens: KeyValueStore.DoubleKey = "networkStakedTokens"
    static let networkStakedUSD: KeyValueStore.DoubleKey = "networkStakedUSD"
}

public extension KeyValueStore.IntKey {
    static let networkSize: KeyValueStore.IntKey = "networkSize"
}

public extension KeyValueStore.Int64Key {
    static let lastUpdatedTimestampMs: KeyValueStore.Int64Key = "lastUpdatedTimestampMs"
    static let staleTimestampMs: KeyValueStore.Int64Key = "staleTimestampMs"
    static let priceTimestampMs: KeyValueStore.Int64Key = "priceTimestampMs"
}
