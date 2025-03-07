// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionSnodeKit
import SessionMessagingKit
import SessionUtilitiesKit

enum NotificationResolution: CustomStringConvertible {
    case success(PushNotificationAPI.NotificationMetadata)
    case successCall
    
    case ignoreDueToMainAppRunning
    case ignoreDueToNoContentFromApple
    case ignoreDueToNonLegacyGroupLegacyNotification
    case ignoreDueToOutdatedMessage
    case ignoreDueToRequiresNoNotification
    case ignoreDueToDuplicateMessage
    case ignoreDueToContentSize(PushNotificationAPI.NotificationMetadata)
    
    case errorTimeout
    case errorNotReadyForExtensions
    case errorNoContentLegacy
    case errorDatabaseInvalid
    case errorDatabaseMigrations(Error)
    case errorTransactionFailure
    case errorLegacyGroupKeysMissing
    case errorCallFailure
    case errorNoContent(PushNotificationAPI.NotificationMetadata)
    case errorProcessing(PushNotificationAPI.ProcessResult)
    case errorMessageHandling(MessageReceiverError)
    case errorOther(Error)
    
    public var description: String {
        switch self {
            case .success(let metadata): return "Completed: Handled notification from namespace: \(metadata.namespace)"
            case .successCall: return "Completed: Notified main app of call message"
            
            case .ignoreDueToMainAppRunning: return "Ignored: Main app running"
            case .ignoreDueToNoContentFromApple: return "Ignored: No content"
            case .ignoreDueToNonLegacyGroupLegacyNotification: return "Ignored: Non-group legacy notification"
            case .ignoreDueToOutdatedMessage: return "Ignored: Alteady seen message"
            case .ignoreDueToRequiresNoNotification: return "Ignored: Message requires no notification"
            
            case .ignoreDueToDuplicateMessage:
                return "Ignored: Duplicate message (probably received it just before going to the background)"
            
            case .ignoreDueToContentSize(let metadata):
                return "Ignored: Notification content from namespace: \(metadata.namespace) was too long: \(metadata.dataLength)"
            
            case .errorTimeout: return "Failed: Execution time expired"
            case .errorNotReadyForExtensions: return "Failed: App not ready for extensions"
            case .errorNoContentLegacy: return "Failed: Legacy notification contained invalid payload"
            case .errorDatabaseInvalid: return "Failed: Database in invalid state"
            case .errorDatabaseMigrations(let error): return "Failed: Database migration error: \(error)"
            case .errorTransactionFailure: return "Failed: Unexpected database transaction rollback"
            case .errorLegacyGroupKeysMissing: return "Failed: No legacy group decryption keys"
            case .errorCallFailure: return "Failed: Failed to handle call message"
            
            case .errorNoContent(let metadata):
                return "Failed: Notification from namespace: \(metadata.namespace) contained no content, expected dataLength: \(metadata.dataLength)"
                
            case .errorProcessing(let result): return "Failed: Unable to process notification (\(result))"
            case .errorMessageHandling(let error): return "Failed: Handling the message (\(error))"
            case .errorOther(let error): return "Error: Unhandled error occurred (\(error))"
        }
    }
    
    public var logLevel: Log.Level {
        switch self {
            case .success, .successCall, .ignoreDueToMainAppRunning, .ignoreDueToNoContentFromApple,
                .ignoreDueToNonLegacyGroupLegacyNotification, .ignoreDueToOutdatedMessage,
                .ignoreDueToRequiresNoNotification, .ignoreDueToDuplicateMessage, .ignoreDueToContentSize:
                return .info
                
            case .errorNotReadyForExtensions, .errorNoContentLegacy, .errorNoContent, .errorCallFailure:
                return .warn
                
            case .errorTimeout, .errorDatabaseInvalid, .errorDatabaseMigrations, .errorTransactionFailure,
                    .errorLegacyGroupKeysMissing, .errorProcessing, .errorMessageHandling, .errorOther:
                return .error
        }
    }
}
