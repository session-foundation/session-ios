// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

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
    public var logs: [LogOutput] = []
    
    func clearLogs() { logs = [] }
    
    nonisolated public func shouldLog(level: Log.Level, categories: [Log.Category]) -> Bool {
        return true
    }
    public func setDefaultLogLevel(_ level: Log.Level?) {}
    public func setLogLevel(_ level: Log.Level?, for category: Log.Category) {}
    public func resetAllLogLevelsToDefaults() {}
    public func loadExtensionLogsAndResumeLogging() {}
    public func clearCache() {}
    nonisolated public func log(_ info: Log.LogInfo) {
        Task { await append(info) }
    }
    nonisolated public func stopLogging(completion: (@Sendable () -> Void)?) { completion?() }
    
    private func append(_ info: Log.LogInfo) {
        logs.append(
            LogOutput(
                level: info.level,
                categories: info.categories,
                message: info.message,
                file: "\(info.file)",
                function: "\(info.function)"
            )
        )
    }
}
