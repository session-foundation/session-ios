// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

enum NotificationResolution: CustomStringConvertible {
    case success(PushNotificationAPI.NotificationMetadata)
    case successCall
    
    case ignoreDueToMainAppRunning
    case ignoreDueToNoContentFromApple
    case ignoreDueToNonLegacyGroupLegacyNotification
    case ignoreDueToSelfSend
    case ignoreDueToOutdatedMessage
    case ignoreDueToRequiresNoNotification
    case ignoreDueToMessageRequest
    case ignoreDueToDuplicateMessage
    case ignoreDueToDuplicateCall
    case ignoreDueToContentSize(PushNotificationAPI.NotificationMetadata)
    
    case errorTimeout
    case errorNotReadyForExtensions
    case errorLegacyPushNotification
    case errorCallFailure
    case errorNoContent(PushNotificationAPI.NotificationMetadata)
    case errorProcessing(PushNotificationAPI.ProcessResult)
    case errorMessageHandling(MessageReceiverError, PushNotificationAPI.NotificationMetadata)
    case errorOther(Error)
    
    public var description: String {
        switch self {
            case .success(let metadata):
                return "Completed: Handled notification from \(metadata.messageOriginString)"
            
            case .successCall: return "Completed: Notified main app of call message"
            
            case .ignoreDueToMainAppRunning: return "Ignored: Main app running"
            case .ignoreDueToNoContentFromApple: return "Ignored: No content"
            case .ignoreDueToNonLegacyGroupLegacyNotification: return "Ignored: Non-group legacy notification"
            case .ignoreDueToSelfSend: return "Ignored: Self send"
            case .ignoreDueToOutdatedMessage: return "Ignored: Already seen message"
            case .ignoreDueToRequiresNoNotification: return "Ignored: Message requires no notification"
            case .ignoreDueToMessageRequest: return "Ignored: Subsequent message in message request"
            
            case .ignoreDueToDuplicateMessage:
                return "Ignored: Duplicate message (probably received it just before going to the background)"
                
            case .ignoreDueToDuplicateCall:
                return "Ignored: Duplicate call (probably received after the call ended)"
            
            case .ignoreDueToContentSize(let metadata):
                return "Ignored: Notification content from \(metadata.messageOriginString) was too long (\(Format.fileSize(UInt(metadata.dataLength))))"
            
            case .errorTimeout: return "Failed: Execution time expired"
            case .errorNotReadyForExtensions: return "Failed: App not ready for extensions"
            case .errorLegacyPushNotification: return "Failed: Legacy push notifications are no longer supported"
            case .errorCallFailure: return "Failed: Failed to handle call message"
            
            case .errorNoContent(let metadata):
                return "Failed: Notification from \(metadata.messageOriginString) contained no content, expected dataLength (\(Format.fileSize(UInt(metadata.dataLength))))"
                
            case .errorProcessing(let result): return "Failed: Unable to process notification (\(result))"
            case .errorMessageHandling(let error, let metadata):
                return "Failed: Handling the message (\(error)) from \(metadata.messageOriginString)"
            case .errorOther(let error): return "Error: Unhandled error occurred (\(error))"
        }
    }
    
    public var logLevel: Log.Level {
        switch self {
            case .success, .successCall, .ignoreDueToMainAppRunning, .ignoreDueToNoContentFromApple,
                .ignoreDueToSelfSend, .ignoreDueToNonLegacyGroupLegacyNotification,
                .ignoreDueToOutdatedMessage, .ignoreDueToRequiresNoNotification,
                .ignoreDueToMessageRequest, .ignoreDueToDuplicateMessage, .ignoreDueToDuplicateCall,
                .ignoreDueToContentSize:
                return .info
                
            case .errorNotReadyForExtensions, .errorLegacyPushNotification, .errorNoContent, .errorCallFailure:
                return .warn
                
            case .errorTimeout, .errorProcessing, .errorMessageHandling, .errorOther:
                return .error
        }
    }
}

internal extension PushNotificationAPI.NotificationMetadata {
    var messageOriginString: String {
        guard self != .invalid else { return "decryption failure" }
        
        return "namespace \(namespace) for accountId \(accountId)"
    }
}
