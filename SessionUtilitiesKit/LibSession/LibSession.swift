// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil

// MARK: - LibSession

public enum LibSession {
    public static var version: String { String(cString: LIBSESSION_UTIL_VERSION_STR) }
}

// MARK: - Logging

extension LibSession {
    public static func addLogger() {
        /// Setup any custom category defaul log levels for libSession
        Log.Category.create("config", defaultLevel: .info)
        Log.Category.create("network", defaultLevel: .info)
        
        /// Set the default log level first (unless specified we only care about semi-dangerous logs)
        session_logger_set_level_default(LOG_LEVEL_WARN)
        
        /// Then set any explicit category log levels we have
        AllLoggingCategories.defaultLevels.forEach { category, level in
            guard
                let cCat: [CChar] = category.rawValue.cString(using: .utf8),
                let cLogLevel: LOG_LEVEL = level.libSession
            else { return }
            
            session_logger_set_level(cCat, cLogLevel)
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
                /// We want to remove the extra data because it doesn't help the logs
                let processedMessage: String = {
                    let logParts: [String] = msg.components(separatedBy: "] ")
                    
                    guard logParts.count == 4 else { return msg.trimmingCharacters(in: .whitespacesAndNewlines) }
                    
                    let message: String = String(logParts[3]).trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    return "\(logParts[1])] \(message)"
                }()
                
                Log.custom(
                    Log.Level(lvl),
                    [Log.Category(rawValue: cat, customPrefix: "libSession:")],
                    processedMessage
                )
            }
        })
    }
    
    public static func clearLoggers() {
        session_clear_loggers()
    }
}

// MARK: - Convenience

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
