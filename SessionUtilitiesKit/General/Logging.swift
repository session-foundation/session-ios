// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SignalCoreKit

public func SNLog(_ message: String) {
    let threadString: String = (Thread.isMainThread ? " Main" : "")
    
    #if DEBUG
    print("[Session\(threadString)] \(message)")
    #endif
    OWSLogger.info("[Session\(threadString)] \(message)")
}

public func SNLogNotTests(_ message: String) {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
    
    SNLog(message)
}
