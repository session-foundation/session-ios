// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

extension MessageReceiver {
    internal static func handleExpirationTimerUpdate(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: ExpirationTimerUpdate
    ) throws {
        guard !Features.useNewDisappearingMessagesConfig else { return }
        guard
            // Only process these for contact and legacy groups (new groups handle it separately)
            (threadVariant == .contact || threadVariant == .legacyGroup),
            let sender: String = message.sender
        else { throw MessageReceiverError.invalidMessage }
        
        // Generate an updated configuration
        //
        // Note: Messages which had been sent during the previous configuration will still
        // use it's settings (so if you enable, send a message and then disable disappearing
        // message then the message you had sent will still disappear)
        let maybeDefaultType: DisappearingMessagesConfiguration.DisappearingMessageType? = {
            switch (threadVariant, threadId == getUserHexEncodedPublicKey(db)) {
                case (.contact, false): return .disappearAfterRead
                case (.legacyGroup, _), (.group, _), (_, true): return .disappearAfterSend
                case (.community, _): return nil // Shouldn't happen
            }
        }()

        guard let defaultType: DisappearingMessagesConfiguration.DisappearingMessageType = maybeDefaultType else { return }
        
        let defaultDuration: DisappearingMessagesConfiguration.DefaultDuration = {
            switch defaultType {
                case .unknown: return .unknown
                case .disappearAfterRead: return .disappearAfterRead
                case .disappearAfterSend: return .disappearAfterSend
            }
        }()
        
        let localConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
            .filter(id: threadId)
            .fetchOne(db)
            .defaulting(to: DisappearingMessagesConfiguration.defaultWith(threadId))
        
        let remoteConfig: DisappearingMessagesConfiguration = localConfig.with(
            // If there is no duration then we should disable the expiration timer
            isEnabled: ((message.duration ?? 0) > 0),
            durationSeconds: (
                message.duration.map { TimeInterval($0) } ??
                defaultDuration.seconds
            ),
            type: defaultType
        )
        
        let timestampMs: Int64 = Int64(message.sentTimestamp ?? 0) // Default to `0` if not set
        
        // Only actually make the change if SessionUtil says we can (we always want to insert the info
        // message though)
        let canPerformChange: Bool = SessionUtil.canPerformChange(
            db,
            threadId: threadId,
            targetConfig: {
                switch threadVariant {
                    case .contact:
                        let currentUserPublicKey: String = getUserHexEncodedPublicKey(db)
                        
                        return (threadId == currentUserPublicKey ? .userProfile : .contacts)
                        
                    default: return .userGroups
                }
            }(),
            changeTimestampMs: timestampMs
        )
        
        // Only update libSession if we can perform the change
        if canPerformChange {
            // Contacts & legacy closed groups need to update the SessionUtil
            switch threadVariant {
                case .contact:
                    try SessionUtil
                        .update(
                            db,
                            sessionId: threadId,
                            disappearingMessagesConfig: remoteConfig
                        )
                
                case .legacyGroup:
                    try SessionUtil
                        .update(
                            db,
                            groupPublicKey: threadId,
                            disappearingConfig: remoteConfig
                        )
                    
                default: break
            }
        }
        
        // Only save the updated config if we can perform the change
        if canPerformChange {
            // Finally save the changes to the DisappearingMessagesConfiguration (If it's a duplicate
            // then the interaction unique constraint will prevent the code from getting here)
            try remoteConfig.save(db)
        }
        
        // Remove previous info messages
        _ = try Interaction
            .filter(Interaction.Columns.threadId == threadId)
            .filter(Interaction.Columns.variant == Interaction.Variant.infoDisappearingMessagesUpdate)
            .deleteAll(db)
        
        // Add an info message for the user
        _ = try Interaction(
            serverHash: nil, // Intentionally null so sync messages are seen as duplicates
            threadId: threadId,
            authorId: sender,
            variant: .infoDisappearingMessagesUpdate,
            body: remoteConfig.messageInfoString(
                with: (sender != getUserHexEncodedPublicKey(db) ?
                    Profile.displayName(db, id: sender) :
                    nil
                ),
                isPreviousOff: false
            ),
            timestampMs: timestampMs,
            expiresInSeconds: (remoteConfig.isEnabled ? nil : localConfig.durationSeconds)
        ).inserted(db)
    }
    
    internal static func updateDisappearingMessagesConfigurationIfNeeded(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: Message,
        proto: SNProtoContent
    ) throws {
        guard let sender: String = message.sender else { return }
        
        // Check the contact's client version based on this received message
        let lastKnownClientVersion: SessionVersion.FeatureVersion = (!proto.hasExpirationTimer ?
            .legacyDisappearingMessages :
            .newDisappearingMessages
        )
        _ = try? Contact
            .filter(id: sender)
            .updateAllAndConfig(
                db,
                Contact.Columns.lastKnownClientVersion.set(to: lastKnownClientVersion)
            )
        
        guard
            Features.useNewDisappearingMessagesConfig,
            proto.hasLastDisappearingMessageChangeTimestamp
        else { return }
        
        let protoLastChangeTimestampMs: Int64 = Int64(proto.lastDisappearingMessageChangeTimestamp)
        let localConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
            .fetchOne(db, id: threadId)
            .defaulting(to: DisappearingMessagesConfiguration.defaultWith(threadId))
        
        let durationSeconds: TimeInterval = (proto.hasExpirationTimer ? TimeInterval(proto.expirationTimer) : 0)
        let disappearingType: DisappearingMessagesConfiguration.DisappearingMessageType? = (proto.hasExpirationType ?
            .init(protoType: proto.expirationType) :
            .unknown
        )
        let remoteConfig: DisappearingMessagesConfiguration = localConfig.with(
            isEnabled: (durationSeconds != 0),
            durationSeconds: durationSeconds,
            type: disappearingType,
            lastChangeTimestampMs: protoLastChangeTimestampMs
        )
        
        let updateControlMewssage: () throws -> () = {
            _ = try Interaction
                .filter(Interaction.Columns.threadId == threadId)
                .filter(Interaction.Columns.variant == Interaction.Variant.infoDisappearingMessagesUpdate)
                .deleteAll(db)

            _ = try Interaction(
                serverHash: nil,
                threadId: threadId,
                authorId: sender,
                variant: .infoDisappearingMessagesUpdate,
                body: remoteConfig.messageInfoString(
                    with: (sender != getUserHexEncodedPublicKey(db) ?
                        Profile.displayName(db, id: sender) :
                        nil
                    ),
                    isPreviousOff: !localConfig.isEnabled
                ),
                timestampMs: protoLastChangeTimestampMs,
                expiresInSeconds: (remoteConfig.isEnabled ? remoteConfig.durationSeconds : localConfig.durationSeconds),
                expiresStartedAtMs: (!remoteConfig.isEnabled && localConfig.type == .disappearAfterSend ?
                    Double(protoLastChangeTimestampMs) :
                    nil
                )
            ).inserted(db)
        }
        
        guard let localLastChangeTimestampMs = localConfig.lastChangeTimestampMs else { return }
        
        guard protoLastChangeTimestampMs >= localLastChangeTimestampMs else {
            if (protoLastChangeTimestampMs + Int64(localConfig.durationSeconds * 1000)) > localLastChangeTimestampMs {
                try updateControlMewssage()
            }
            return
        }
        
        if localConfig != remoteConfig {
            _ = try remoteConfig.save(db)
            
            // Contacts & legacy closed groups need to update the SessionUtil
            switch threadVariant {
                case .contact:
                    try SessionUtil
                        .update(
                            db,
                            sessionId: threadId,
                            disappearingMessagesConfig: remoteConfig
                        )
                
                case .legacyGroup:
                    try SessionUtil
                        .update(
                            db,
                            groupPublicKey: threadId,
                            disappearingConfig: remoteConfig
                        )
                    
                default: break
            }
        }
        
        guard message is ExpirationTimerUpdate else { return }
        
        try updateControlMewssage()
    }
}
