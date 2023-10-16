// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import Sodium
import SessionUtilitiesKit
import SessionSnodeKit

extension MessageReceiver {
    public static func handleGroupUpdateMessage(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: Message,
        using dependencies: Dependencies
    ) throws {
        switch (message, try? SessionId(from: threadId)) {
            case (let message as GroupUpdateInviteMessage, _):
                try MessageReceiver.handleGroupInvite(
                    db,
                    message: message,
                    using: dependencies
                )
                
            case (let message as GroupUpdateDeleteMessage, _):
                try MessageReceiver.handleGroupDelete(
                    db,
                    message: message,
                    using: dependencies
                )
                
            case (let message as GroupUpdateInfoChangeMessage, .some(let sessionId)) where sessionId.prefix == .group:
                try MessageReceiver.handleGroupInfoChanged(
                    db,
                    groupSessionId: sessionId,
                    message: message,
                    using: dependencies
                )
                
            case (let message as GroupUpdateMemberChangeMessage, .some(let sessionId)) where sessionId.prefix == .group:
                try MessageReceiver.handleGroupMemberChanged(
                    db,
                    groupSessionId: sessionId,
                    message: message,
                    using: dependencies
                )
                
            case (let message as GroupUpdatePromoteMessage, .some(let sessionId)) where sessionId.prefix == .group:
                try MessageReceiver.handleGroupPromotion(
                    db,
                    groupSessionId: sessionId,
                    message: message,
                    using: dependencies
                )
                
            case (let message as GroupUpdateMemberLeftMessage, .some(let sessionId)) where sessionId.prefix == .group:
                try MessageReceiver.handleGroupMemberLeft(
                    db,
                    groupSessionId: sessionId,
                    message: message,
                    using: dependencies
                )
                
            case (let message as GroupUpdateInviteResponseMessage, .some(let sessionId)) where sessionId.prefix == .group:
                try MessageReceiver.handleGroupInviteResponse(
                    db,
                    groupSessionId: sessionId,
                    message: message,
                    using: dependencies
                )
                
            case (let message as GroupUpdatePromotionResponseMessage, .some(let sessionId)) where sessionId.prefix == .group:
                try MessageReceiver.handleGroupPromotionResponse(
                    db,
                    groupSessionId: sessionId,
                    message: message,
                    using: dependencies
                )
                
            case (let message as GroupUpdateDeleteMemberContentMessage, .some(let sessionId)) where sessionId.prefix == .group:
                try MessageReceiver.handleGroupDeleteMemberContent(
                    db,
                    groupSessionId: sessionId,
                    message: message,
                    using: dependencies
                )
                
            default: throw MessageReceiverError.invalidMessage
        }
    }
    
    // MARK: - Specific Handling
    
    private static func handleGroupInvite(
        _ db: Database,
        message: GroupUpdateInviteMessage,
        using dependencies: Dependencies
    ) throws {
        guard
            let sender: String = message.sender,
            let sentTimestampMs: UInt64 = message.sentTimestamp
        else { throw MessageReceiverError.invalidMessage }
        
        // Update profile if needed
        if let profile = message.profile {
            try ProfileManager.updateProfileIfNeeded(
                db,
                publicKey: sender,
                name: profile.displayName,
                blocksCommunityMessageRequests: profile.blocksCommunityMessageRequests,
                avatarUpdate: {
                    guard
                        let profilePictureUrl: String = profile.profilePictureUrl,
                        let profileKey: Data = profile.profileKey
                    else { return .remove }
                    
                    return .updateTo(
                        url: profilePictureUrl,
                        key: profileKey,
                        fileName: nil
                    )
                }(),
                sentTimestamp: TimeInterval(sentTimestampMs * 1000),
                using: dependencies
            )
        }
        
        /// With updated groups they should be considered message requests (`invited: true`) unless person sending the invitation is
        /// an approved contact of the user, this is designed to reduce spam via groups getting around message requests if users are on old
        /// or modified clients
        let inviteSenderIsApproved: Bool = ((try? Contact.fetchOne(db, id: sender))?.isApproved == true)
        
        try MessageReceiver.handleNewGroup(
            db,
            groupSessionId: message.groupSessionId.hexString,
            groupIdentityPrivateKey: nil,
            name: message.groupName,
            authData: message.memberAuthData,
            joinedAt: Int64(sentTimestampMs),
            invited: !inviteSenderIsApproved,
            calledFromConfigHandling: false,
            using: dependencies
        )
    }
    
    internal static func handleNewGroup(
        _ db: Database,
        groupSessionId: String,
        groupIdentityPrivateKey: Data?,
        name: String?,
        authData: Data?,
        joinedAt: Int64,
        invited: Bool,
        calledFromConfigHandling: Bool,
        using dependencies: Dependencies
    ) throws {
        // Create the group
        try SessionThread.fetchOrCreate(db, id: groupSessionId, variant: .group, shouldBeVisible: true)
        let closedGroup: ClosedGroup = try ClosedGroup(
            threadId: groupSessionId,
            name: (name ?? "GROUP_TITLE_FALLBACK".localized()),
            formationTimestamp: TimeInterval(joinedAt),
            shouldPoll: false,  // Always false here - will be updated in `approveGroup`
            groupIdentityPrivateKey: groupIdentityPrivateKey,
            authData: authData,
            invited: invited
        ).saved(db)
        
        if !calledFromConfigHandling {
            // Update libSession
            try? SessionUtil.add(
                db,
                groupSessionId: groupSessionId,
                groupIdentityPrivateKey: groupIdentityPrivateKey,
                name: name,
                authData: authData,
                joinedAt: joinedAt,
                invited: invited,
                using: dependencies
            )
        }
        
        // If the group is not in the invite state then handle the approval process
        guard !invited else { return }
        
        try ClosedGroup.approveGroup(
            db,
            group: closedGroup,
            calledFromConfigHandling: calledFromConfigHandling,
            using: dependencies
        )
    }
    
    /// Logic for handling the `GroupUpdateDeleteMessage`
    ///
    /// **Note:** Admins can't be removed from a group so this only clears the `authData`
    private static func handleGroupDelete(
        _ db: Database,
        message: GroupUpdateDeleteMessage,
        using dependencies: Dependencies
    ) throws {
        guard
            let sender: String = message.sender,
            let sentTimestampMs: UInt64 = message.sentTimestamp,
            // TODO: This encryption/decryption approach WILL NOT work (it uses the group encryption keys instead of the group admin key)
            let decryptedData: (plaintext: Data, sender: String) = try? SessionUtil.decrypt(
                ciphertext: message.encryptedMemberAuthData,
                groupSessionId: message.groupSessionId,
                using: dependencies
            )
        else { throw MessageReceiverError.invalidMessage }
        
        let maybeMemberAuthData: Data? = try? ClosedGroup
            .filter(id: message.groupSessionId.hexString)
            .select(.authData)
            .asRequest(of: Data.self)
            .fetchOne(db)
        
        // We don't have any authData stored so just ignore the message
        guard let memberAuthData: Data = maybeMemberAuthData else { return }
        
        // Delete the group data (Want to keep the group itself around because the user was kicked and
        // the UX of conversations randomly disappearing isn't great)
        try ClosedGroup.removeData(
            db,
            threadIds: [message.groupSessionId.hexString],
            dataToRemove: [
                .poller, .pushNotifications, .messages,
                .members, .encryptionKeys, .libSessionState
            ],
            calledFromConfigHandling: false,
            using: dependencies
        )
    }
    
    private static func handleGroupInfoChanged(
        _ db: Database,
        groupSessionId: SessionId,
        message: GroupUpdateInfoChangeMessage,
        using dependencies: Dependencies
    ) throws {
        guard
            let sender: String = message.sender,
            let sentTimestampMs: UInt64 = message.sentTimestamp
        else { throw MessageReceiverError.invalidMessage }
        
        // Add a record of the specific change to the conversation (the actual change is handled via
        // config messages so these are only for record purposes)
        switch message.changeType {
            case .name:
                _ = try Interaction(
                    serverHash: message.serverHash,
                    threadId: groupSessionId.hexString,
                    authorId: sender,
                    variant: .infoGroupUpdated,
                    body: message.updatedName
                        .map { ClosedGroup.MessageInfo.updatedName($0) }
                        .defaulting(to: ClosedGroup.MessageInfo.updatedNameFallback)
                        .infoString,
                    timestampMs: Int64(sentTimestampMs)
                ).inserted(db)
                
            case .avatar:
                _ = try Interaction(
                    serverHash: message.serverHash,
                    threadId: groupSessionId.hexString,
                    authorId: sender,
                    variant: .infoGroupUpdated,
                    body: ClosedGroup.MessageInfo
                        .updatedDisplayPicture
                        .infoString,
                    timestampMs: Int64(sentTimestampMs)
                ).inserted(db)
                
            case .disappearingMessages:
                /// **Note:** We only create this in order to get the 'messageInfoString' it **should not** be saved as that would
                /// override the correct settings applied by the group config messages
                let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
                let relevantConfig: DisappearingMessagesConfiguration = DisappearingMessagesConfiguration(
                    threadId: groupSessionId.hexString,
                    isEnabled: ((message.updatedExpiration ?? 0) > 0),
                    durationSeconds: TimeInterval((message.updatedExpiration ?? 0)),
                    type: .disappearAfterSend,
                    lastChangeTimestampMs: Int64(sentTimestampMs)
                )
                let localConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
                    .filter(id: groupSessionId.hexString)
                    .fetchOne(db)
                    .defaulting(to: DisappearingMessagesConfiguration.defaultWith(groupSessionId.hexString))
                
                _ = try Interaction(
                    serverHash: message.serverHash,
                    threadId: groupSessionId.hexString,
                    authorId: sender,
                    variant: .infoDisappearingMessagesUpdate,
                    body: relevantConfig.messageInfoString(
                        with: (sender != userSessionId.hexString ?
                            Profile.displayName(db, id: sender) :
                            nil
                        ),
                        isPreviousOff: false
                    ),
                    timestampMs: Int64(sentTimestampMs),
                    wasRead: SessionUtil.timestampAlreadyRead(
                        threadId: groupSessionId.hexString,
                        threadVariant: .group,
                        timestampMs: Int64(sentTimestampMs),
                        userSessionId: userSessionId,
                        openGroup: nil,
                        using: dependencies
                    ),
                    expiresInSeconds: (relevantConfig.isEnabled ? nil : localConfig.durationSeconds)
                ).inserted(db)
        }
    }
    
    private static func handleGroupMemberChanged(
        _ db: Database,
        groupSessionId: SessionId,
        message: GroupUpdateMemberChangeMessage,
        using dependencies: Dependencies
    ) throws {
        guard
            let sender: String = message.sender,
            let sentTimestampMs: UInt64 = message.sentTimestamp
        else { throw MessageReceiverError.invalidMessage }
        
        let profiles: [String: Profile] = (try? Profile
            .filter(ids: message.memberPublicKeys.map { $0.toHexString() })
            .fetchAll(db))
            .defaulting(to: [])
            .reduce(into: [:]) { result, next in result[next.id] = next }
        let names: [String] = message.memberPublicKeys.map { idData in
            profiles[idData.toHexString()]?.displayName(for: .group) ??
            Profile.truncated(id: idData.toHexString(), truncating: .middle)
        }
        
        // Add a record of the specific change to the conversation (the actual change is handled via
        // config messages so these are only for record purposes)
        _ = try Interaction(
            threadId: groupSessionId.hexString,
            authorId: sender,
            variant: .infoGroupUpdated,
            body: {
                switch message.changeType {
                    case .added: return ClosedGroup.MessageInfo.addedUsers(names: names).infoString
                    case .removed: return ClosedGroup.MessageInfo.removedUsers(names: names).infoString
                    case .promoted: return ClosedGroup.MessageInfo.promotedUsers(names: names).infoString
                }
            }(),
            timestampMs: Int64(sentTimestampMs)
        ).inserted(db)
    }
    
    private static func handleGroupPromotion(
        _ db: Database,
        groupSessionId: SessionId,
        message: GroupUpdatePromoteMessage,
        using dependencies: Dependencies
    ) throws {
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        
        // Current user wasn't promoted, ignore the message
        guard message.memberPublicKey.toHexString() == userSessionId.hexString else { return }
        
    }
    
    private static func handleGroupMemberLeft(
        _ db: Database,
        groupSessionId: SessionId,
        message: GroupUpdateMemberLeftMessage,
        using dependencies: Dependencies
    ) throws {
        guard
            let sender: String = message.sender,
            let sentTimestampMs: UInt64 = message.sentTimestamp
        else { throw MessageReceiverError.invalidMessage }
        
        // Add a record of the specific change to the conversation (the actual change is handled via
        // config messages so these are only for record purposes)
        _ = try Interaction(
            threadId: groupSessionId.hexString,
            authorId: sender,
            variant: .infoGroupUpdated,
            body: ClosedGroup.MessageInfo
                .memberLeft(
                    name: (
                        (try? Profile.fetchOne(db, id: sender)?.displayName(for: .group)) ??
                        Profile.truncated(id: sender, truncating: .middle)
                    )
                )
                .infoString,
            timestampMs: Int64(sentTimestampMs)
        ).inserted(db)
        
        // If the user is a group admin then we need to remove the member from the group, we already have a
        // "member left" message so `sendMemberChangedMessage` should be `false`
        guard ClosedGroup.filter(id: groupSessionId.hexString).select(.groupIdentityPrivateKey).isNotEmpty(db) else {
            return
        }
        
        try MessageSender.removeGroupMembers(
            db,
            groupSessionId: groupSessionId,
            memberIds: [sender],
            sendMemberChangedMessage: false,
            changeTimestampMs: Int64(sentTimestampMs),
            using: dependencies
        )
    }
    
    private static func handleGroupInviteResponse(
        _ db: Database,
        groupSessionId: SessionId,
        message: GroupUpdateInviteResponseMessage,
        using dependencies: Dependencies
    ) throws {
        guard
            let sender: String = message.sender,
            let sentTimestampMs: UInt64 = message.sentTimestamp
        else { throw MessageReceiverError.invalidMessage }
        
        // Update profile if needed
        if let profile = message.profile {
            try ProfileManager.updateProfileIfNeeded(
                db,
                publicKey: sender,
                name: profile.displayName,
                blocksCommunityMessageRequests: profile.blocksCommunityMessageRequests,
                avatarUpdate: {
                    guard
                        let profilePictureUrl: String = profile.profilePictureUrl,
                        let profileKey: Data = profile.profileKey
                    else { return .remove }
                    
                    return .updateTo(
                        url: profilePictureUrl,
                        key: profileKey,
                        fileName: nil
                    )
                }(),
                sentTimestamp: TimeInterval(sentTimestampMs * 1000),
                using: dependencies
            )
        }
        
        // When a user accepts a group invitation only admins should action the change
        guard ClosedGroup.filter(id: groupSessionId.hexString).select(.groupIdentityPrivateKey).isNotEmpty(db) else {
            throw MessageReceiverError.invalidMessage
        }
        
        let existingMember: GroupMember? = try GroupMember
            .filter(
                GroupMember.Columns.groupId == groupSessionId.hexString &&
                GroupMember.Columns.profileId == sender
            )
            .fetchOne(db)
        
        switch existingMember?.role {
            case .none, .admin:
                // If the 'GroupMember' entry in the database doesn't exist or is an admin then
                // don't change the database as we assume it's state is correct, just update `libSession`
                // in case it didn't have the correct `invited` state (if this triggers a GROUP_MEMBERS
                // update then the database will eventually get back to a valid state)
                try SessionUtil.updateMemberStatus(
                    db,
                    groupSessionId: groupSessionId,
                    memberId: sender,
                    role: .standard,
                    status: .accepted,
                    using: dependencies
                )
                
            case .standard:
                try GroupMember(
                    groupId: groupSessionId.hexString,
                    profileId: sender,
                    role: .standard,
                    roleStatus: .accepted,
                    isHidden: false
                ).update(db)
                
            default: break  // Invalid cases
        }
    }
    
    private static func handleGroupPromotionResponse(
        _ db: Database,
        groupSessionId: SessionId,
        message: GroupUpdatePromotionResponseMessage,
        using dependencies: Dependencies
    ) throws {
        guard let sender: String = message.sender else { throw MessageReceiverError.invalidMessage }
        
        
        // Upsert the 'GroupMember' entry into the database (this will trigger a libSession update)
        try GroupMember(
            groupId: groupSessionId.hexString,
            profileId: sender,
            role: .admin,
            roleStatus: .accepted,
            isHidden: false
        ).upsert(db)
    }
    
    private static func handleGroupDeleteMemberContent(
        _ db: Database,
        groupSessionId: SessionId,
        message: GroupUpdateDeleteMemberContentMessage,
        using dependencies: Dependencies
    ) throws {
        guard
            let sender: String = message.sender,
            let sentTimestampMs: UInt64 = message.sentTimestamp
        else { throw MessageReceiverError.invalidMessage }
        
        try Interaction
            .filter(
                Interaction.Columns.threadId == groupSessionId.hexString &&
                message.memberPublicKeys.contains(Interaction.Columns.authorId) &&
                Interaction.Columns.timestampMs < sentTimestampMs
            )
            .deleteAll(db)
    }
}
