// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

@testable import SessionMessagingKit

class MockSessionUtilCache: Mock<SessionUtilCacheType>, SessionUtilCacheType {
    var isEmpty: Bool { return accept() as! Bool }
    var needsSync: Bool { return accept() as! Bool }
    
    func setConfig(for variant: ConfigDump.Variant, sessionId: SessionId, to config: SessionUtil.Config?) {
        accept(args: [variant, sessionId, config])
    }
    
    func config(for variant: ConfigDump.Variant, sessionId: SessionId) -> Atomic<SessionUtil.Config?> {
        return accept(args: [variant, sessionId]) as! Atomic<SessionUtil.Config?>
    }
    
    func removeAll() {
        accept()
    }
}
