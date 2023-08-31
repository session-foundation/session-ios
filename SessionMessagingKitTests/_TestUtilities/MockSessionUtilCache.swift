// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

@testable import SessionMessagingKit

class MockSessionUtilCache: Mock<SessionUtilCacheType>, SessionUtilCacheType {
    var isEmpty: Bool { return accept() as! Bool }
    var needsSync: Bool { return accept() as! Bool }
    
    func setConfig(for variant: ConfigDump.Variant, publicKey: String, to config: SessionUtil.Config?) {
        accept(args: [variant, publicKey, config])
    }
    
    func config(for variant: ConfigDump.Variant, publicKey: String) -> Atomic<SessionUtil.Config?> {
        return accept(args: [variant, publicKey]) as! Atomic<SessionUtil.Config?>
    }
    
    func removeAll() {
        accept()
    }
}
