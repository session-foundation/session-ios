// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionMessagingKit

enum NotificationError: LocalizedError {
    case processing(PushNotificationAPI.ProcessResult)
    case messageProcessing
    case messageHandling(MessageReceiverError)
    
    public var errorDescription: String? {
        switch self {
            case .processing(let result): return "Failed to process notification (\(result))"
            case .messageProcessing: return "Failed to process message"
            case .messageHandling(let error): return "Failed to handle message (\(error))"
        }
    }
}
