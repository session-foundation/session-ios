// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Quick
import TestUtilities

public extension AsyncSpec {
    static func itTracked(
        _ description: String,
        fileID: String = #fileID,
        file: String = #file,
        line: UInt = #line,
        closure: @escaping () async throws -> Void
    ) {
        it(description, file: file, line: line) {
            try await withTestContext(fileID: fileID, file: file, line: line) {
                try await closure()
            }
        }
    }
    
    static func fitTracked(
        _ description: String,
        fileID: String = #fileID,
        file: String = #file,
        line: UInt = #line,
        closure: @escaping () async throws -> Void
    ) {
        fit(description, file: file, line: line) {
            try await withTestContext(fileID: fileID, file: file, line: line) {
                try await closure()
            }
        }
    }
}
