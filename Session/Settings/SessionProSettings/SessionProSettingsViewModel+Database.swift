// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SessionUtilitiesKit

public extension KeyValueStore.IntKey {
    static let groupsUpgradedCounter: KeyValueStore.IntKey = "groupsUpgradedCounter"
    static let pinnedConversationsCounter: KeyValueStore.IntKey = "pinnedConversationsCounter"
    static let proBadgesSentCounter: KeyValueStore.IntKey = "proBadgesSentCounter"
    static let longerMessagesSentCounter: KeyValueStore.IntKey = "longerMessagesSentCounter"
}
