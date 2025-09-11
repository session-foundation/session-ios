// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

@testable import SessionUtilitiesKit

public actor MockLogger: LoggerType {
    public struct LogOutput: Equatable {
        let level: Log.Level
        let categories: [Log.Category]
        let message: String
        let file: String
        let function: String
        
        /// We don't include the `line` because it'd make test maintenance a pain
        /// `let line: UInt`
    }
    
    nonisolated public let primaryPrefix: String = "Mock"
    nonisolated public let sortedLogFilePaths: [String]? = nil
    public let isSuspended: Bool = false
    public var logs: [LogOutput] = []
    
    func clearLogs() { logs = [] }
    
    public func setPendingLogsRetriever(_ callback: @escaping () -> [Log.LogInfo]) {}
    public func loadExtensionLogsAndResumeLogging() {}
    public func _internalLog(
        _ level: Log.Level,
        _ categories: [Log.Category],
        _ message: String,
        file: String,
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
