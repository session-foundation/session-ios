// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil

// MARK: - LibSession

public enum LibSession {
    public static var version: String { String(cString: LIBSESSION_UTIL_VERSION_STR) }
}

// MARK: - Log.Category

public extension Log.Category {
    static let libSession: Log.Category = .create("LibSession", defaultLevel: .info)
}

public extension Log.Group {
    static let libSession: Log.Group = .create("libSession", defaultLevel: .info)
}

// MARK: - Logging

extension LibSession {
    public static func setupLogger(using dependencies: Dependencies) {
        /// Setup any custom category default log levels for libSession
        Log.Category.create("config", defaultLevel: .info)
        Log.Category.create("network", defaultLevel: .info)
        
        /// Subscribe for log level changes (this will emit an initial event which we can use to set the default log level)
        Task {
            for await _ in dependencies.stream(feature: .allLogLevels) {
                let currentLogLevels: [Log.Category: Log.Level] = dependencies[feature: .allLogLevels]
                    .currentValues(using: dependencies)
                let currentGroupLogLevels: [Log.Group: Log.Level] = dependencies[feature: .allLogLevels]
                    .currentValues(using: dependencies)
                let targetDefault: Log.Level? = min(
                    (currentLogLevels[.default] ?? .off),
                    (currentGroupLogLevels[.libSession] ?? .off)
                )
                let cDefaultLevel: LOG_LEVEL = (targetDefault?.libSession ?? LOG_LEVEL_OFF)
                session_logger_set_level_default(cDefaultLevel)
                session_logger_reset_level(cDefaultLevel)
                
                /// Update all explicit log levels (we don't want to register a listener for each individual one so just re-apply all)
                ///
                /// If the conversation to the libSession `LOG_LEVEL` fails then it means we should use the default log level
                currentLogLevels.forEach { (category: Log.Category, level: Log.Level) in
                    guard
                        let cCat: [CChar] = category.rawValue.cString(using: .utf8),
                        let cLogLevel: LOG_LEVEL = level.libSession
                    else { return }
                    
                    session_logger_set_level(cCat, cLogLevel)
                }
            }
        }
        
        /// Finally register the actual logger callback
        session_add_logger_full({ msgPtr, msgLen, catPtr, catLen, lvl in
            guard
                let msg: String = String(pointer: msgPtr, length: msgLen, encoding: .utf8),
                let cat: String = String(pointer: catPtr, length: catLen, encoding: .utf8)
            else { return }
            
            /// Dispatch to another thread so we don't block thread triggering the log
            DispatchQueue.global(qos: .background).async {
                /// Logs from libSession come through in the format:
                /// `[yyyy-MM-dd hh:mm:ss] [+{lifetime}s] [{cat}:{lvl}|log.hpp:{line}] {message}`
                ///
                /// We want to simplify the message because our logging already includes category and timestamp information:
                /// `[+{lifetime}s] {message}`
                let trimmedMsg = msg.trimmingCharacters(in: .whitespacesAndNewlines)
                
                guard
                    let timestampRegex: NSRegularExpression = LibSession.timestampRegex,
                    let messageStartRegex: NSRegularExpression = LibSession.messageStartRegex,
                    let fileLineRegex: NSRegularExpression = LibSession.fileLineRegex
                else {
                    return Log.custom(Log.Level(lvl), [Log.Category(rawValue: cat, group: .libSession)], trimmedMsg)
                }
                
                let fullRange = NSRange(trimmedMsg.startIndex..<trimmedMsg.endIndex, in: trimmedMsg)
                let timestamp: String? = {
                    if let match = timestampRegex.firstMatch(in: trimmedMsg, range: fullRange),
                       let swiftRange = Range(match.range, in: trimmedMsg) {
                        return String(trimmedMsg[swiftRange])
                    }
                    return nil
                }()
                let message: String? = {
                    if let match = messageStartRegex.firstMatch(in: trimmedMsg, range: fullRange),
                       match.numberOfRanges == 2, // Ensure our capture group (1) was found
                       let swiftRange = Range(match.range(at: 1), in: trimmedMsg) {
                        return String(trimmedMsg[swiftRange])
                    }
                    return nil
                }()
                let (filename, line): (String?, UInt?) = {
                    if let match = fileLineRegex.firstMatch(in: trimmedMsg, range: fullRange),
                       match.numberOfRanges == 3 { // We expect 3 ranges: the full match, filename, and line
                        
                        let fileString = Range(match.range(at: 1), in: trimmedMsg).map { String(trimmedMsg[$0]) }
                        let lineString = Range(match.range(at: 2), in: trimmedMsg).map { String(trimmedMsg[$0]) }
                        
                        if let fileString = fileString, let lineString = lineString, let lineUInt = UInt(lineString) {
                            return (fileString, lineUInt)
                        }
                    }
                    return (nil, nil)
                }()
                
                let processedMessage: String = {
                    switch (timestamp, message) {
                        case (.some(let timestamp), .some(let message)) where !timestamp.isEmpty && !message.isEmpty:
                            return "\(timestamp) \(message)"
                        default: return trimmedMsg
                    }
                }()
                
                switch (filename, line) {
                    case (.some(let filename), .some(let line)):
                        Log.custom(
                            Log.Level(lvl),
                            [Log.Category(rawValue: cat, group: .libSession)],
                            processedMessage,
                            file: filename,
                            line: line
                        )
                    
                    default:
                        Log.custom(
                            Log.Level(lvl),
                            [Log.Category(rawValue: cat, group: .libSession)],
                            processedMessage
                        )
                }
            }
        })
    }
    
    public static func clearLoggers() {
        session_clear_loggers()
    }
}

// MARK: - Convenience

fileprivate extension LibSession {
    static let timestampRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\[\\+(?:(?:\\d+w)?(?:\\d+d)?(?:\\d+h)?(?:\\d+m)?)?\\d+(?:\\.\\d+)?s\\]"
    )
    static let messageStartRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\[.*?\\|.*?\\.(?:c|cpp|h|hpp):\\d+\\]\\s*(.*)",
        options: .dotMatchesLineSeparators
    )
    static let fileLineRegex: NSRegularExpression? = try? NSRegularExpression(
        pattern: "\\|([^:]+):(\\d+)\\]"
    )
}

fileprivate extension Log.Level {
    var libSession: LOG_LEVEL? {
        switch self {
            case .verbose: return LOG_LEVEL_TRACE
            case .debug: return LOG_LEVEL_DEBUG
            case .info: return LOG_LEVEL_INFO
            case .warn: return LOG_LEVEL_WARN
            case .error: return LOG_LEVEL_ERROR
            case .critical: return LOG_LEVEL_CRITICAL
            case .off: return LOG_LEVEL_OFF
            case .default: return nil   // It'll use the default value by default so just return nil
        }
    }
    
    init(_ level: LOG_LEVEL) {
        switch level {
            case LOG_LEVEL_TRACE: self = .verbose
            case LOG_LEVEL_DEBUG: self = .debug
            case LOG_LEVEL_INFO: self = .info
            case LOG_LEVEL_WARN: self = .warn
            case LOG_LEVEL_ERROR: self = .error
            case LOG_LEVEL_CRITICAL: self = .critical
            default: self = .off
        }
    }
}
