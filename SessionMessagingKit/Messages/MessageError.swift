// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public enum MessageError: Error, CustomStringConvertible {
    case encodingFailed
    case decodingFailed
    case invalidMessage(String)
    case missingRequiredField(String?)
    
    case duplicateMessage
    case duplicatedCall
    case outdatedMessage
    case ignorableMessage
    case ignorableMessageRequestMessage
    case deprecatedMessage
    case protoConversionFailed
    case unknownMessage(SNProtoContent?)
    
    case requiredSignatureMissing
    case invalidConfigMessageHandling
    case invalidRevokedRetrievalMessageHandling
    case invalidGroupUpdate(String)
    case communitiesDoNotSupportControlMessages
    case requiresGroupId(String)
    case requiresGroupIdentityPrivateKey
    
    case selfSend
    case invalidSender
    case senderBlocked
    case messageRequiresThreadToExistButThreadDoesNotExist
    case sendFailure(Log.Category?, String, Error)
    
    public static let missingRequiredField: MessageError = .missingRequiredField(nil)
    
    public var shouldUpdateLastHash: Bool {
        switch self {
            /// If we get one of these errors then we still want to update the last hash to prevent retrieving and attempting to process
            /// the same messages again (as well as ensure the next poll doesn't retrieve the same message - these errors are essentially
            /// considered "already successfully processed")
            case .duplicateMessage, .duplicatedCall, .outdatedMessage, .selfSend:
                return true
                
            default: return false
        }
    }
    
    public var description: String {
        switch self {
            case .encodingFailed: return "Failed to encode message."
            case .decodingFailed: return "Failed to decode message."
            case .invalidMessage(let reason): return "Invalid message (\(reason))."
            case .missingRequiredField(let field):
                return "Message missing required field\(field.map { ": \($0)" } ?? "")."
            
            case .duplicateMessage: return "Duplicate message."
            case .duplicatedCall: return "Duplicate call."
            case .outdatedMessage: return "Message was sent before a config change which would have removed the message."
            case .ignorableMessage: return "Message should be ignored."
            case .ignorableMessageRequestMessage: return "Message request message should be ignored."
            case .deprecatedMessage: return "This message type has been deprecated."
            case .protoConversionFailed: return "Failed to convert to protobuf message."
            case .unknownMessage(let content):
                switch content {
                    case .none: return "Unknown message type (no content)."
                    case .some(let content):
                        let protoInfo: [(String, Bool)] = [
                            ("hasDataMessage", (content.dataMessage != nil)),
                            ("hasProfile", (content.dataMessage?.profile != nil)),
                            ("hasBody", (content.dataMessage?.hasBody == true)),
                            ("hasAttachments", (content.dataMessage?.attachments.isEmpty == false)),
                            ("hasReaction", (content.dataMessage?.reaction != nil)),
                            ("hasQuote", (content.dataMessage?.quote != nil)),
                            ("hasLinkPreview", (content.dataMessage?.preview != nil)),
                            ("hasOpenGroupInvitation", (content.dataMessage?.openGroupInvitation != nil)),
                            ("hasGroupV2ControlMessage", (content.dataMessage?.groupUpdateMessage != nil)),
                            ("hasTimestamp", (content.dataMessage?.hasTimestamp == true)),
                            ("hasSyncTarget", (content.dataMessage?.hasSyncTarget == true)),
                            ("hasBlocksCommunityMessageRequests", (content.dataMessage?.hasBlocksCommunityMessageRequests == true)),
                            ("hasCallMessage", (content.callMessage != nil)),
                            ("hasReceiptMessage", (content.receiptMessage != nil)),
                            ("hasTypingMessage", (content.typingMessage != nil)),
                            ("hasDataExtractionMessage", (content.dataExtractionNotification != nil)),
                            ("hasUnsendRequest", (content.unsendRequest != nil)),
                            ("hasMessageRequestResponse", (content.messageRequestResponse != nil)),
                            ("hasExpirationTimer", (content.hasExpirationTimer == true)),
                            ("hasExpirationType", (content.hasExpirationType == true)),
                            ("hasSigTimestamp", (content.hasSigTimestamp == true))
                        ]
                        
                        let protoInfoString: String = protoInfo
                            .filter { _, val in val }
                            .map { name, _ in name }
                            .joined(separator: ", ")
                        return "Unknown message type (\(protoInfoString))."
                }
            
            case .requiredSignatureMissing: return "Required signature missing."
            case .invalidConfigMessageHandling: return "Invalid handling of a config message."
            case .invalidRevokedRetrievalMessageHandling: return "Invalid handling of a revoked retrieval message."
            case .invalidGroupUpdate(let reason): return "Invalid group update (\(reason))."
            case .communitiesDoNotSupportControlMessages: return "Communities do not support control messages."
            case .requiresGroupId(let id): return "Required group id but was given: \(id)"
            case .requiresGroupIdentityPrivateKey: return "Requires group identity private key"
                
            case .selfSend: return "Message addressed at self."
            case .invalidSender: return "Invalid sender."
            case .senderBlocked: return "Received a message from a blocked user."
                
            case .messageRequiresThreadToExistButThreadDoesNotExist: return "Message requires a thread to exist before processing the message but the thread does not exist."
            case .sendFailure(_, _, let error): return "\(error)"
        }
    }
}
