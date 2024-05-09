// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SignalCoreKit

// MARK: - LibSession

public enum LibSession {
    private static let logLevels: [LogCategory: LOG_LEVEL] = [
        .config: LOG_LEVEL_INFO,
        .network: LOG_LEVEL_INFO
    ]
    
    public static var version: String { String(cString: LIBSESSION_UTIL_VERSION_STR) }
}

// MARK: - Logging

extension LibSession {
    public static func addLogger() {
        // Set the desired log levels first
        logLevels.forEach { cat, level in
            session_logger_set_level(cat.rawValue.cArray, level)
        }
        
        // Add the logger
        session_add_logger_full({ msgPtr, msgLen, _, _, lvl in
            guard let msg: String = String(pointer: msgPtr, length: msgLen, encoding: .utf8) else { return }
            
            let trimmedLog: String = msg.trimmingCharacters(in: .whitespacesAndNewlines)
            switch lvl {
                case LOG_LEVEL_TRACE: OWSLogger.verbose(trimmedLog)
                case LOG_LEVEL_DEBUG: OWSLogger.debug(trimmedLog)
                case LOG_LEVEL_INFO: OWSLogger.info(trimmedLog)
                case LOG_LEVEL_WARN: OWSLogger.warn(trimmedLog)
                case LOG_LEVEL_ERROR: OWSLogger.error(trimmedLog)
                case LOG_LEVEL_CRITICAL: OWSLogger.error(trimmedLog)
                case LOG_LEVEL_OFF: break
                default: break
            }
            
            #if DEBUG
            print(trimmedLog)
            #endif
        })
    }
    
    // MARK: - Internal
    
    fileprivate enum LogCategory: String {
        case config
        case network
        case quic
        
        init?(_ catPtr: UnsafePointer<CChar>?, _ catLen: Int) {
            switch String(pointer: catPtr, length: catLen, encoding: .utf8).map({ LogCategory(rawValue: $0) }) {
                case .some(let cat): self = cat
                case .none: return nil
            }
        }
    }
}
