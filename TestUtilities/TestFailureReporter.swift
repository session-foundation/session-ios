// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public protocol TestFailureReporter {
    /// Reports a fatal error for the current test case, stopping its execution
    func reportFailure(_ message: String, fileID: String, file: String, line: UInt)
}

public extension TestFailureReporter {
    func reportFailure(_ message: String, fileID: String = #fileID, file: String = #filePath, line: UInt = #line) {
        reportFailure(message, fileID: fileID, file: file, line: line)
    }
}
