// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public final class TestContext {
    public var fileID: String = #fileID
    public var file: String = #filePath
    public var line: UInt = #line

    @TaskLocal public static var current: TestContext?
}

public func withTestContext<T>(
    fileID: String = #fileID,
    file: String = #file,
    line: UInt = #line,
    _ body: () async throws -> T
) async rethrows -> T {
    let context: TestContext = TestContext()
    context.fileID = fileID
    context.file = file
    context.line = line
    
    return try await TestContext.$current.withValue(context) {
        try await body()
    }
}

