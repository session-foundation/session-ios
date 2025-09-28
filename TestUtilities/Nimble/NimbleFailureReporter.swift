// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
internal import Nimble

public struct NimbleFailureReporter: TestFailureReporter {
    public init() {}
    
    public func reportFailure(_ message: String, fileID: String, file: String, line: UInt) {
        fail(message, fileID: fileID, file: file, line: line)
    }
}
