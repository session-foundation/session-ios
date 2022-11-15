// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SignalCoreKit
import SessionUtilitiesKit

extension MessageReceiver {
    internal static func handleSyncedExpiriesMessage(
        _ db: Database,
        message: SyncedExpiriesMessage,
        dependencies: SMKDependencies
    ) throws {
        print("Ryan Test: Receive SyncedExpiriesMessage")
    }
}
