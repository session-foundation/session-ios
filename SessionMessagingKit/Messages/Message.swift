// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

/// Abstract base class for `VisibleMessage` and `ControlMessage`.
public class Message: Codable {
    public enum CodingKeys: String, CodingKey {
        case id
        case sentTimestampMs = "sentTimestamp"
        case receivedTimestampMs = "receivedTimestamp"
        case sender
        case openGroupServerMessageId
        case openGroupWhisper
        case openGroupWhisperMods
        case openGroupWhisperTo
        case serverHash
        
        case expiresInSeconds
        case expiresStartedAtMs
        
        case proProof
    }
    
    public var id: String?
    public var sentTimestampMs: UInt64?
    public var sigTimestampMs: UInt64?
    public var receivedTimestampMs: UInt64?
    public var sender: String?
    public var openGroupServerMessageId: UInt64?
    public var openGroupWhisper: Bool
    public var openGroupWhisperMods: Bool
    public var openGroupWhisperTo: String?
    
    public var serverHash: String?
    public var ttl: UInt64 { 14 * 24 * 60 * 60 * 1000 }
    public var isSelfSendValid: Bool { false }
    
    public var shouldBeRetryable: Bool { false }
    public var processWithBlockedSender: Bool { false }
    
    // MARK: - Disappearing Messages
    public var expiresInSeconds: TimeInterval?
    public var expiresStartedAtMs: Double?
    
    public var proProof: String?

    // MARK: - Validation
    
    public func isValid(isSending: Bool) -> Bool {
        guard
            let sentTimestampMs: UInt64 = sentTimestampMs,
            sentTimestampMs > 0,
            sender != nil
        else { return false }
        
        /// If this is an incoming message then ensure we also have a received timestamp
        if !isSending {
            guard
                let receivedTimestampMs: UInt64 = receivedTimestampMs,
                receivedTimestampMs > 0
            else { return false }
        }
        
        /// We added a new `sigTimestampMs` which is included in the message data so can be verified as part of the signature
        /// to have been sent from the sender but legacy clients won't include this value so when `contentTimestampMs` isn't present
        /// we should consider `sentTimestampMs` as valid even though we can't confirm it was sent by the sender
        ///
        /// If `contentTimestampMs` is present then we should confirm that it matches the `sentTimestampMs` (if it doesn't then
        /// this message could have been manipulated)
        ///
        /// **Note:** In community conversations the `sentTimestampMs` is the server timestamp that the message was `posted`
        /// at, due to this we need to allow for some variation between the values
        switch (isSending, sigTimestampMs, openGroupServerMessageId) {
            case (_, .some(let sigTimestampMs), .none), (true, .some(let sigTimestampMs), .some):
                return (sigTimestampMs == sentTimestampMs)
            
            /// Outgoing messages to a community should have matching `sigTimestampMs` and `sentTimestampMs`
            /// values as they are set locally, when we get a response from the community we update the `sentTimestampMs` to
            /// be the `posted` value returned from the API which is where timestamp variation needs to be supported
            case (false, .some(let sigTimestampMs), .some):
                let delta: TimeInterval = (TimeInterval(max(sigTimestampMs, sentTimestampMs) - min(sigTimestampMs, sentTimestampMs)) / 1000)
                
                return delta < OpenGroupAPI.validTimestampVarianceThreshold
                
            // FIXME: We want to remove support for this case in a future release
            case (_, .none, _): return true
        }
    }
    
    // MARK: - Initialization
    
    public init(
        id: String? = nil,
        sentTimestampMs: UInt64? = nil,
        receivedTimestampMs: UInt64? = nil,
        sender: String? = nil,
        openGroupServerMessageId: UInt64? = nil,
        openGroupWhisper: Bool = false,
        openGroupWhisperMods: Bool = false,
        openGroupWhisperTo: String? = nil,
        serverHash: String? = nil,
        expiresInSeconds: TimeInterval? = nil,
        expiresStartedAtMs: Double? = nil,
        proProof: String? = nil
    ) {
        self.id = id
        self.sentTimestampMs = sentTimestampMs
        self.receivedTimestampMs = receivedTimestampMs
        self.sender = sender
        self.openGroupServerMessageId = openGroupServerMessageId
        self.openGroupWhisper = openGroupWhisper
        self.openGroupWhisperMods = openGroupWhisperMods
        self.openGroupWhisperTo = openGroupWhisperTo
        self.serverHash = serverHash
        self.expiresInSeconds = expiresInSeconds
        self.expiresStartedAtMs = expiresStartedAtMs
        self.proProof = proProof
    }

    // MARK: - Proto Conversion
    
    public class func fromProto(_ proto: SNProtoContent, sender: String, using dependencies: Dependencies) -> Self? {
        preconditionFailure("fromProto(_:sender:) is abstract and must be overridden.")
    }

    public func toProto() -> SNProtoContent? {
        preconditionFailure("toProto() is abstract and must be overridden.")
    }
    
    public func setDisappearingMessagesConfigurationIfNeeded(on proto: SNProtoContent.SNProtoContentBuilder) {
        if let expiresInSeconds = self.expiresInSeconds {
            proto.setExpirationTimer(UInt32(expiresInSeconds))
        } else {
            proto.setExpirationTimer(0)
            proto.setExpirationType(.unknown)
            return
        }
        
        if let expiresStartedAtMs = self.expiresStartedAtMs, UInt64(expiresStartedAtMs) == self.sentTimestampMs {
            proto.setExpirationType(.deleteAfterSend)
        } else {
            proto.setExpirationType(.deleteAfterRead)
        }
    }
    
    public func attachDisappearingMessagesConfiguration(from proto: SNProtoContent) {
        let expiresInSeconds: TimeInterval? = proto.hasExpirationTimer ? TimeInterval(proto.expirationTimer) : nil
        let expiresStartedAtMs: Double? = {
            if proto.expirationType == .deleteAfterSend, let timestamp = self.sentTimestampMs {
                return Double(timestamp)
            }
            return nil
        }()
        
        self.expiresInSeconds = expiresInSeconds
        self.expiresStartedAtMs = expiresStartedAtMs
    }
}

// MARK: - Message Parsing/Processing

public protocol NotProtoConvertible {}

public enum ProcessedMessage {
    case standard(
        threadId: String,
        threadVariant: SessionThread.Variant,
        proto: SNProtoContent,
        messageInfo: MessageReceiveJob.Details.MessageInfo,
        uniqueIdentifier: String
    )
    case config(
        publicKey: String,
        namespace: SnodeAPI.Namespace,
        serverHash: String,
        serverTimestampMs: Int64,
        data: Data,
        uniqueIdentifier: String
    )
    case invalid
    
    public var threadId: String {
        switch self {
            case .standard(let threadId, _, _, _, _): return threadId
            case .config(let publicKey, _, _, _, _, _): return publicKey
            case .invalid: return ""
        }
    }
    
    var namespace: SnodeAPI.Namespace {
        switch self {
            case .standard(_, let threadVariant, _, _, _):
                switch threadVariant {
                    case .group: return .groupMessages
                    case .legacyGroup: return .legacyClosedGroup
                    case .contact, .community: return .default
                }
                
            case .config(_, let namespace, _, _, _, _): return namespace
            case .invalid: return .default
        }
    }
    
    var uniqueIdentifier: String {
        switch self {
            case .standard(_, _, _, _, let uniqueIdentifier): return uniqueIdentifier
            case .config(_, _, _, _, _, let uniqueIdentifier): return uniqueIdentifier
            case .invalid: return ""
        }
    }
    
    var isConfigMessage: Bool {
        switch self {
            case .standard: return false
            case .config: return true
            case .invalid: return false
        }
    }
}

// MARK: - Variant

public extension Message {
    enum Variant: String, Codable, CaseIterable {
        case readReceipt
        case typingIndicator
        case dataExtractionNotification
        case expirationTimerUpdate
        case unsendRequest
        case messageRequestResponse
        case visibleMessage
        case callMessage
        case groupUpdateInvite
        case groupUpdatePromote
        case groupUpdateInfoChange
        case groupUpdateMemberChange
        case groupUpdateMemberLeft
        case groupUpdateMemberLeftNotification
        case groupUpdateInviteResponse
        case groupUpdateDeleteMemberContent
        case libSessionMessage
        
        init?(from type: Message) {
            switch type {
                case is ReadReceipt: self = .readReceipt
                case is TypingIndicator: self = .typingIndicator
                case is DataExtractionNotification: self = .dataExtractionNotification
                case is ExpirationTimerUpdate: self = .expirationTimerUpdate
                case is UnsendRequest: self = .unsendRequest
                case is MessageRequestResponse: self = .messageRequestResponse
                case is VisibleMessage: self = .visibleMessage
                case is CallMessage: self = .callMessage
                case is GroupUpdateInviteMessage: self = .groupUpdateInvite
                case is GroupUpdatePromoteMessage: self = .groupUpdatePromote
                case is GroupUpdateInfoChangeMessage: self = .groupUpdateInfoChange
                case is GroupUpdateMemberChangeMessage: self = .groupUpdateMemberChange
                case is GroupUpdateMemberLeftMessage: self = .groupUpdateMemberLeft
                case is GroupUpdateMemberLeftNotificationMessage: self = .groupUpdateMemberLeftNotification
                case is GroupUpdateInviteResponseMessage: self = .groupUpdateInviteResponse
                case is GroupUpdateDeleteMemberContentMessage: self = .groupUpdateDeleteMemberContent
                case is LibSessionMessage: self = .libSessionMessage
                default: return nil
            }
        }
        
        var messageType: Message.Type {
            switch self {
                case .readReceipt: return ReadReceipt.self
                case .typingIndicator: return TypingIndicator.self
                case .dataExtractionNotification: return DataExtractionNotification.self
                case .expirationTimerUpdate: return ExpirationTimerUpdate.self
                case .unsendRequest: return UnsendRequest.self
                case .messageRequestResponse: return MessageRequestResponse.self
                case .visibleMessage: return VisibleMessage.self
                case .callMessage: return CallMessage.self
                case .groupUpdateInvite: return GroupUpdateInviteMessage.self
                case .groupUpdatePromote: return GroupUpdatePromoteMessage.self
                case .groupUpdateInfoChange: return GroupUpdateInfoChangeMessage.self
                case .groupUpdateMemberChange: return GroupUpdateMemberChangeMessage.self
                case .groupUpdateMemberLeft: return GroupUpdateMemberLeftMessage.self
                case .groupUpdateMemberLeftNotification: return GroupUpdateMemberLeftNotificationMessage.self
                case .groupUpdateInviteResponse: return GroupUpdateInviteResponseMessage.self
                case .groupUpdateDeleteMemberContent: return GroupUpdateDeleteMemberContentMessage.self
                case .libSessionMessage: return LibSessionMessage.self
            }
        }
        
        /// This value ensures the variants can be ordered to ensure the correct types are processed and aren't parsed as the wrong type
        /// due to the structures being close enough matches
        var protoPriority: Int {
            let priorities: [Variant] = [
                .readReceipt,
                .typingIndicator,
                .groupUpdateInvite,
                .groupUpdatePromote,
                .groupUpdateInfoChange,
                .groupUpdateMemberChange,
                .groupUpdateMemberLeft,
                .groupUpdateMemberLeftNotification,
                .groupUpdateInviteResponse,
                .groupUpdateDeleteMemberContent,
                .dataExtractionNotification,
                .expirationTimerUpdate,
                .unsendRequest,
                .messageRequestResponse,
                .visibleMessage,
                .callMessage,
                .libSessionMessage
            ]
            
            return (priorities.firstIndex(of: self) ?? priorities.count)
        }
        
        var isProtoConvetible: Bool {
            return !(self.messageType is NotProtoConvertible.Type)
        }
        
        func decode<CodingKeys: CodingKey>(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Message {
            switch self {
                case .readReceipt: return try container.decode(ReadReceipt.self, forKey: key)
                case .typingIndicator: return try container.decode(TypingIndicator.self, forKey: key)
                    
                case .dataExtractionNotification:
                    return try container.decode(DataExtractionNotification.self, forKey: key)
                    
                case .expirationTimerUpdate: return try container.decode(ExpirationTimerUpdate.self, forKey: key)
                case .unsendRequest: return try container.decode(UnsendRequest.self, forKey: key)
                case .messageRequestResponse: return try container.decode(MessageRequestResponse.self, forKey: key)
                case .visibleMessage: return try container.decode(VisibleMessage.self, forKey: key)
                case .callMessage: return try container.decode(CallMessage.self, forKey: key)
                
                case .groupUpdateInvite: return try container.decode(GroupUpdateInviteMessage.self, forKey: key)
                case .groupUpdatePromote: return try container.decode(GroupUpdatePromoteMessage.self, forKey: key)
                
                case .groupUpdateInfoChange:
                    return try container.decode(GroupUpdateInfoChangeMessage.self, forKey: key)
                                                                                
                case .groupUpdateMemberChange:
                    return try container.decode(GroupUpdateMemberChangeMessage.self, forKey: key)
                
                case .groupUpdateMemberLeft:
                    return try container.decode(GroupUpdateMemberLeftMessage.self, forKey: key)
                
                case .groupUpdateMemberLeftNotification:
                    return try container.decode(GroupUpdateMemberLeftNotificationMessage.self, forKey: key)
                
                case .groupUpdateInviteResponse:
                    return try container.decode(GroupUpdateInviteResponseMessage.self, forKey: key)
                
                case .groupUpdateDeleteMemberContent:
                    return try container.decode(GroupUpdateDeleteMemberContentMessage.self, forKey: key)
                    
                case .libSessionMessage: return try container.decode(LibSessionMessage.self, forKey: key)
            }
        }
    }
}

public extension Message {
    static func createMessageFrom(_ proto: SNProtoContent, sender: String, using dependencies: Dependencies) throws -> Message {
        let decodedMessage: Message? = Variant
            .allCases
            .sorted { lhs, rhs -> Bool in lhs.protoPriority < rhs.protoPriority }
            .filter { variant -> Bool in variant.isProtoConvetible }
            .reduce(nil) { prev, variant in
                guard prev == nil else { return prev }
                
                return variant.messageType.fromProto(proto, sender: sender, using: dependencies)
            }
        
        return try decodedMessage ?? { throw MessageReceiverError.unknownMessage(proto) }()
    }
    
    static func shouldSync(message: Message) -> Bool {
        switch message {
            case is VisibleMessage: return true
            case is ExpirationTimerUpdate: return true
            case is UnsendRequest: return true
            
            case let callMessage as CallMessage:
                switch callMessage.kind {
                    case .answer, .endCall: return true
                    default: return false
                }
            
            default: return false
        }
    }
    
    static func threadId(
        forMessage message: Message,
        destination: Message.Destination,
        using dependencies: Dependencies
    ) -> String {
        switch destination {
            /// One-to-one conversations are actually stored twice (once on the recipients swarm and once on the current users swarm),
            /// as a result when we send a message it needs to be sent to both swarms, this means that we can't just assume the public
            /// key for the `destination` is associated to the conversation for this message (because all outgoing messages would
            /// have the current users public key)
            ///
            /// In order to get around this we set the `syncTarget` value when storing an outgoing one-to-one message on our own
            /// swarm, and can use it to determine what the original destination of the message was
            case .contact(let publicKey), .syncMessage(let publicKey):
                let maybeSyncTarget: String?
                
                switch message {
                    case let message as VisibleMessage: maybeSyncTarget = message.syncTarget
                    case let message as ExpirationTimerUpdate: maybeSyncTarget = message.syncTarget
                    default: maybeSyncTarget = nil
                }
                
                /// A bug once popped up where the `syncTarget` was incorrectly set for an incoming message and, as a result,
                /// the incoming message appeared within the "Note to Self" conversation so as some defensive coding we check
                /// if the `maybeSyncTarget` matches the current users id and, if so, use the `publicKey` instead
                let userSessionId: SessionId = dependencies[cache: .general].sessionId
                
                guard maybeSyncTarget != userSessionId.hexString else { return publicKey }
                
                return (maybeSyncTarget ?? publicKey)
                
            case .closedGroup(let groupPublicKey): return groupPublicKey
            case .openGroup(let roomToken, let server, _, _):
                return OpenGroup.idFor(roomToken: roomToken, server: server)
            
            case .openGroupInbox(_, _, let blindedPublicKey): return blindedPublicKey
        }
    }
    
    static func processRawReceivedReactions(
        _ db: ObservingDatabase,
        openGroupId: String,
        message: OpenGroupAPI.Message,
        associatedPendingChanges: [OpenGroupAPI.PendingChange],
        using dependencies: Dependencies
    ) -> [Reaction] {
        guard
            let reactions: [String: OpenGroupAPI.Message.Reaction] = message.reactions,
            let openGroupCapabilityInfo: LibSession.OpenGroupCapabilityInfo = try? LibSession.OpenGroupCapabilityInfo
                .fetchOne(db, id: openGroupId)
        else { return [] }
        
        let currentUserSessionId: SessionId = dependencies[cache: .general].sessionId
        let currentUserSessionIds: Set<String> = Set([
            currentUserSessionId,
            SessionThread.getCurrentUserBlindedSessionId(
                threadId: openGroupId,
                threadVariant: .community,
                blindingPrefix: .blinded15,
                openGroupCapabilityInfo: openGroupCapabilityInfo,
                using: dependencies
            ),
            SessionThread.getCurrentUserBlindedSessionId(
                threadId: openGroupId,
                threadVariant: .community,
                blindingPrefix: .blinded25,
                openGroupCapabilityInfo: openGroupCapabilityInfo,
                using: dependencies
            )
        ].compactMap { $0 }.map { $0.hexString })
        
        return reactions
            .reduce(into: []) { result, next in
                guard
                    let decodedEmoji: String = next.key.removingPercentEncoding,
                    next.value.count > 0,
                    let reactors: [String] = next.value.reactors
                else { return }
                
                // Decide whether we need to ignore all reactions
                let pendingChangeRemoveAllReaction: Bool = associatedPendingChanges
                    .contains { pendingChange in
                        if case .reaction(_, let emoji, let action) = pendingChange.metadata {
                            return emoji == decodedEmoji && action == .removeAll
                        }
                        
                        return false
                    }
                
                // Decide whether we need to add an extra reaction from current user
                let pendingChangeSelfReaction: Bool? = {
                    // Find the newest 'PendingChange' entry with a matching emoji, if one exists, and
                    // set the "self reaction" value based on it's action
                    let maybePendingChange: OpenGroupAPI.PendingChange? = associatedPendingChanges
                        .sorted(by: { lhs, rhs -> Bool in (lhs.seqNo ?? Int64.max) >= (rhs.seqNo ?? Int64.max) })
                        .first { pendingChange in
                            if case .reaction(_, let emoji, _) = pendingChange.metadata {
                                return emoji == decodedEmoji
                            }
                            
                            return false
                        }
                    
                    // If there is no pending change for this reaction then return nil
                    guard
                        let pendingChange: OpenGroupAPI.PendingChange = maybePendingChange,
                        case .reaction(_, _, let action) = pendingChange.metadata
                    else { return nil }

                    // Otherwise add/remove accordingly
                    return action == .add
                }()
                let shouldAddSelfReaction: Bool = (
                    pendingChangeSelfReaction ?? (
                        (next.value.you || !Set(reactors).isDisjoint(with: currentUserSessionIds)) &&
                        !pendingChangeRemoveAllReaction
                    )
                )
                
                let count: Int64 = (next.value.you ? next.value.count - 1 : next.value.count)
                let timestampMs: Int64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
                let maxLength: Int = shouldAddSelfReaction ? 4 : 5
                let desiredReactorIds: [String] = reactors
                    .filter { !currentUserSessionIds.contains($0) } // Remove current user for now, will add back if needed
                    .prefix(maxLength)
                    .map { $0 }
                
                // Add the first reaction (with the count)
                if !pendingChangeRemoveAllReaction, let firstReactor: String = desiredReactorIds.first {
                    result.append(
                        Reaction(
                            interactionId: message.id,
                            serverHash: nil,
                            timestampMs: timestampMs,
                            authorId: firstReactor,
                            emoji: decodedEmoji,
                            count: count,
                            sortId: next.value.index
                        )
                    )
                }
                
                // Add all other reactions
                if desiredReactorIds.count > 1 && !pendingChangeRemoveAllReaction {
                    result.append(
                        contentsOf: desiredReactorIds
                            .suffix(from: 1)
                            .map { reactor in
                                Reaction(
                                    interactionId: message.id,
                                    serverHash: nil,
                                    timestampMs: timestampMs,
                                    authorId: reactor,
                                    emoji: decodedEmoji,
                                    count: 0,   // Only want this on the first reaction
                                    sortId: next.value.index
                                )
                            }
                    )
                }
                
                // Add the current user reaction (if applicable and not already included)
                if shouldAddSelfReaction {
                    result.append(
                        Reaction(
                            interactionId: message.id,
                            serverHash: nil,
                            timestampMs: timestampMs,
                            authorId: currentUserSessionId.hexString,
                            emoji: decodedEmoji,
                            count: 1,
                            sortId: next.value.index
                        )
                    )
                }
            }
    }
    
    // MARK: - TTL for disappearing messages
    
    internal static func getSpecifiedTTL(
        message: Message,
        destination: Message.Destination,
        using dependencies: Dependencies
    ) -> UInt64 {
        // Not disappearing messages
        guard message.expiresInSeconds != nil else { return message.ttl }
        
        switch (destination, message) {
            // Disappear after sent messages with exceptions
            case (_, is UnsendRequest): return message.ttl
            
            case (.closedGroup, is GroupUpdateInviteMessage), (.closedGroup, is GroupUpdateInviteResponseMessage),
                (.closedGroup, is GroupUpdatePromoteMessage), (.closedGroup, is GroupUpdateMemberLeftMessage),
                (.closedGroup, is GroupUpdateDeleteMemberContentMessage):
                return message.ttl

            default:
                guard
                    let expiresInSeconds = message.expiresInSeconds,     // Not disappearing messages
                    expiresInSeconds > 0,                                // Not disappearing messages (0 == disabled)
                    let expiresStartedAtMs = message.expiresStartedAtMs, // Unread disappear after read message
                    message.sentTimestampMs == UInt64(expiresStartedAtMs)// Already read disappearing messages
                else { return message.ttl }
                
                return UInt64(expiresInSeconds * 1000)
        }
    }
}

// MARK: - Conversion

public extension Interaction.Variant {
    /// This function can be used to create an `Interaction.Variant` from a `Message` instance
    init?(message: Message, currentUserSessionIds: Set<String>) {
        switch message {
            case is ReadReceipt, is TypingIndicator, is UnsendRequest, is GroupUpdatePromoteMessage,
                is GroupUpdateMemberLeftMessage, is GroupUpdateInviteResponseMessage,
                is GroupUpdateDeleteMemberContentMessage, is LibSessionMessage:
                return nil
                
            case is TypingIndicator: return nil
            case let message as DataExtractionNotification:
                self = (message.kind == .screenshot ?
                    .infoScreenshotNotification :
                    .infoMediaSavedNotification
                )
            
            case is ExpirationTimerUpdate: self = .infoDisappearingMessagesUpdate
            case is MessageRequestResponse: self = .infoMessageRequestAccepted
            
            case let message as VisibleMessage:
                self = (currentUserSessionIds.contains(message.sender ?? "") ?
                    .standardOutgoing :
                    .standardIncoming
                )
            
            case is CallMessage: self = .infoCall
            case is GroupUpdateInviteMessage: self = .infoGroupInfoInvited
            case is GroupUpdateInfoChangeMessage: self = .infoGroupInfoUpdated
            case is GroupUpdateMemberChangeMessage: self = .infoGroupMembersUpdated
            case is GroupUpdateMemberLeftNotificationMessage: self = .infoGroupMembersUpdated
            default: return nil
        }
    }
}

// MARK: - Mutation

public extension Message {
    func with(sentTimestampMs: UInt64) -> Self {
        self.sentTimestampMs = sentTimestampMs
        return self
    }
    
    func with(_ disappearingMessagesConfiguration: DisappearingMessagesConfiguration?) -> Self {
        self.expiresInSeconds = disappearingMessagesConfiguration?.durationSeconds
        if disappearingMessagesConfiguration?.type == .disappearAfterSend, let sentTimestampMs = self.sentTimestampMs {
            self.expiresStartedAtMs =  Double(sentTimestampMs)
        }
        return self
    }
    
    func with(
        expiresInSeconds: TimeInterval?,
        expiresStartedAtMs: Double? = nil
    ) -> Self {
        self.expiresInSeconds = expiresInSeconds
        self.expiresStartedAtMs = expiresStartedAtMs
        return self
    }
    
    func with(proProof: String?) -> Self {
        self.proProof = proProof
        return self
    }
}
