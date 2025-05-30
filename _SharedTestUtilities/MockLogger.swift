// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

@testable import SessionUtilitiesKit

public class MockLogger: Logger {
    public struct LogOutput: Equatable {
        let level: Log.Level
        let categories: [Log.Category]
        let message: String
        let file: String
        let function: String
        
        /// We don't include the `line` because it'd make test maintenance a pain
        /// `let line: UInt`
    }
    
    public var logs: [LogOutput] = []
    
    public override func _internalLog(
        _ level: Log.Level,
        _ categories: [Log.Category],
        _ message: String,
        file: StaticString,
        function: StaticString,
        line: UInt
    ) {
        logs.append(
            LogOutput(
                level: level,
                categories: categories,
                message: message,
                file: "\(file)",
                function: "\(function)"
            )
        )
    }
}
