// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public enum MessageReceiverError: Error, CustomStringConvertible {
    case duplicateMessage
    case invalidMessage
    case invalidSender
    case unknownMessage(SNProtoContent?)
    case unknownEnvelopeType
    case noUserX25519KeyPair
    case noUserED25519KeyPair
    case invalidSignature
    case noData
    case senderBlocked
    case noThread
    case selfSend
    case decryptionFailed
    case noGroupKeyPair
    case invalidConfigMessageHandling
    case outdatedMessage
    case ignorableMessage
    case ignorableMessageRequestMessage
    case duplicatedCall
    case missingRequiredAdminPrivileges
    case deprecatedMessage
    case originalMessageNotFound

    public var isRetryable: Bool {
        switch self {
            case .duplicateMessage, .invalidMessage, .unknownMessage, .unknownEnvelopeType,
                .invalidSignature, .noData, .senderBlocked, .noThread, .selfSend, .decryptionFailed,
                .invalidConfigMessageHandling, .outdatedMessage, .ignorableMessage, .ignorableMessageRequestMessage,
                .missingRequiredAdminPrivileges, .originalMessageNotFound:
                return false
                
            default: return true
        }
    }
    
    public var shouldUpdateLastHash: Bool {
        switch self {
            // If we get one of these errors then we still want to update the last hash to prevent
            // retrieving and attempting to process the same messages again (as well as ensure the
            // next poll doesn't retrieve the same message - these errors are essentially considered
            // "already successfully processed")
            case .selfSend, .duplicateMessage, .outdatedMessage, .missingRequiredAdminPrivileges:
                return true
                
            default: return false
        }
    }

    public var description: String {
        switch self {
            case .duplicateMessage: return "Duplicate message."
            case .invalidMessage: return "Invalid message."
            case .invalidSender: return "Invalid sender."
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
                
            case .unknownEnvelopeType: return "Unknown envelope type."
            case .noUserX25519KeyPair: return "Couldn't find user X25519 key pair."
            case .noUserED25519KeyPair: return "Couldn't find user ED25519 key pair."
            case .invalidSignature: return "Invalid message signature."
            case .noData: return "Received an empty envelope."
            case .senderBlocked: return "Received a message from a blocked user."
            case .noThread: return "Couldn't find thread for message."
            case .selfSend: return "Message addressed at self."
            case .decryptionFailed: return "Decryption failed."
            
            // Shared sender keys
            case .noGroupKeyPair: return "Missing group key pair."
                
            case .invalidConfigMessageHandling: return "Invalid handling of a config message."
            case .outdatedMessage: return "Message was sent before a config change which would have removed the message."
            case .ignorableMessage: return "Message should be ignored."
            case .ignorableMessageRequestMessage: return "Message request message should be ignored."
            case .duplicatedCall: return "Duplicate call."
            case .missingRequiredAdminPrivileges: return "Handling this message requires admin privileges which the current user does not have."
            case .deprecatedMessage: return "This message type has been deprecated."
            case .originalMessageNotFound: return "Original message not found."
        }
    }
}
