// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

class MockGeneralCache: Mock<GeneralCacheType>, GeneralCacheType {
    var sessionId: SessionId? {
        get { return accept() as? SessionId }
        set { accept(args: [newValue]) }
    }
    
    var recentReactionTimestamps: [Int64] {
        get { return (accept() as? [Int64] ?? []) }
        set { accept(args: [newValue]) }
    }
}
