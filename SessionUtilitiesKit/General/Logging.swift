// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SignalCoreKit

public func SNLog(_ message: String) {
    #if DEBUG
    print("[Session] \(message)")
    #endif
    OWSLogger.info("[Session] \(message)")
}

public func SNLogNotTests(_ message: String) {
    guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
    
    SNLog(message)
}
