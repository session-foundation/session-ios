// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import Sodium
import SessionUtilitiesKit

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
                
            case (let message as GroupUpdatePromoteMessage, _):
                try MessageReceiver.handleGroupPromotion(
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
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        
        guard
            let sender: String = message.sender,
            let sentTimestampMs: UInt64 = message.sentTimestamp,
            Authentication.verify(
                signature: message.adminSignature,
                publicKey: message.groupSessionId.publicKey,
                verificationBytes: GroupUpdateInviteMessage.generateVerificationBytes(
                    inviteeSessionIdHexString: userSessionId.hexString,
                    timestampMs: sentTimestampMs
                ),
                using: dependencies
            )
        else { throw MessageReceiverError.invalidMessage }
        
        // Update profile if needed
        if let profile = message.profile {
            try Profile.updateIfNeeded(
                db,
                publicKey: sender,
                name: profile.displayName,
                blocksCommunityMessageRequests: profile.blocksCommunityMessageRequests,
                displayPictureUpdate: {
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
                sentTimestamp: TimeInterval(Double(sentTimestampMs) / 1000),
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
            joinedAt: TimeInterval(Double(sentTimestampMs) / 1000),
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
        joinedAt: TimeInterval,
        invited: Bool,
        calledFromConfigHandling: Bool,
        using dependencies: Dependencies
    ) throws {
        // Create the group
        try SessionThread.fetchOrCreate(
            db,
            id: groupSessionId,
            variant: .group,
            shouldBeVisible: true,
            calledFromConfigHandling: calledFromConfigHandling,
            using: dependencies
        )
        let closedGroup: ClosedGroup = try ClosedGroup(
            threadId: groupSessionId,
            name: (name ?? "GROUP_TITLE_FALLBACK".localized()),
            formationTimestamp: joinedAt,
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
    
    /// Logic for handling the `GroupUpdateDeleteMessage`, this message should only be processed if it was sent
    /// after the user joined the group (while unlikely, it's possible to receive this message when re-joining a group after
    /// previously being kicked in which case we don't want to delete the data)
    ///
    /// **Note:** Admins can't be removed from a group so this only clears the `authData`
    private static func handleGroupDelete(
        _ db: Database,
        message: GroupUpdateDeleteMessage,
        using dependencies: Dependencies
    ) throws {
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        
        guard
            let sentTimestampMs: UInt64 = message.sentTimestamp,
            let groupJoinedAt: TimeInterval = try? ClosedGroup
                .filter(id: message.groupSessionId.hexString)
                .select(ClosedGroup.Columns.formationTimestamp)
                .asRequest(of: TimeInterval.self)
                .fetchOne(db),
            sentTimestampMs > UInt64(groupJoinedAt * 1000),
            Authentication.verify(
                signature: message.adminSignature,
                publicKey: message.groupSessionId.publicKey,
                verificationBytes: GroupUpdateDeleteMessage.generateVerificationBytes(
                    recipientSessionIdHexString: userSessionId.hexString,
                    timestampMs: sentTimestampMs
                ),
                using: dependencies
            )
        else { throw MessageReceiverError.invalidMessage }
        
        // Delete the group data (want to keep the group itself around because the UX of conversations
        // randomly disappearing isn't great)
        try ClosedGroup.removeData(
            db,
            threadIds: [message.groupSessionId.hexString],
            dataToRemove: [
                .poller, .pushNotifications, .messages, .members,
                .encryptionKeys, .authDetails, .libSessionState
            ],
            calledFromConfigHandling: false,
            using: dependencies
        )
    }
    
    private static func handleGroupPromotion(
        _ db: Database,
        message: GroupUpdatePromoteMessage,
        using dependencies: Dependencies
    ) throws {
        guard
            let userEdKeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db, using: dependencies),
            let groupIdentityKeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                .ed25519KeyPair(seed: message.groupIdentitySeed, using: dependencies)
            )
        else { throw MessageReceiverError.invalidMessage }
        
        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
        let groupSessionId: SessionId = SessionId(.group, publicKey: groupIdentityKeyPair.publicKey)
        
        // Reload the libSession config state for the group to have the admin key
        try SessionUtil
            .reloadState(
                db,
                for: groupSessionId,
                userEd25519SecretKey: userEdKeyPair.secretKey,
                groupEd25519SecretKey: groupIdentityKeyPair.secretKey,
                using: dependencies
            )
        
        // Replace the member key with the admin key in the database
        try ClosedGroup
            .filter(id: groupSessionId.hexString)
            .updateAll( // Intentionally not calling 'updateAllAndConfig' as we want to explicitly make changes
                db,
                ClosedGroup.Columns.groupIdentityPrivateKey.set(to: Data(groupIdentityKeyPair.secretKey)),
                ClosedGroup.Columns.authData.set(to: nil)
            )
        
        // Upsert the 'GroupMember' entry into the database (this will trigger a libSession update)
        try GroupMember(
            groupId: groupSessionId.hexString,
            profileId: userSessionId.hexString,
            role: .admin,
            roleStatus: .accepted,
            isHidden: false
        ).upsert(db)
        
        // Update the current user to be an admin in the 'GROUP_MEMBERS' state
        try SessionUtil
            .updateMemberStatus(
                db,
                groupSessionId: groupSessionId,
                memberId: userSessionId.hexString,
                role: .admin,
                status: .accepted,
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
                    variant: .infoGroupInfoUpdated,
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
                    variant: .infoGroupInfoUpdated,
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
            .filter(ids: message.memberSessionIds)
            .fetchAll(db))
            .defaulting(to: [])
            .reduce(into: [:]) { result, next in result[next.id] = next }
        let names: [String] = message.memberSessionIds.map { id in
            profiles[id]?.displayName(for: .group) ??
            Profile.truncated(id: id, truncating: .middle)
        }
        
        // Add a record of the specific change to the conversation (the actual change is handled via
        // config messages so these are only for record purposes)
        _ = try Interaction(
            threadId: groupSessionId.hexString,
            authorId: sender,
            variant: .infoGroupMembersUpdated,
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
            variant: .infoGroupMembersUpdated,
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
        
        MessageSender
            .removeGroupMembers(
                groupSessionId: groupSessionId.hexString,
                memberIds: [sender],
                removeTheirMessages: false,
                sendMemberChangedMessage: false,
                changeTimestampMs: Int64(sentTimestampMs),
                using: dependencies
            )
            .sinkUntilComplete()
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
            try Profile.updateIfNeeded(
                db,
                publicKey: sender,
                name: profile.displayName,
                blocksCommunityMessageRequests: profile.blocksCommunityMessageRequests,
                displayPictureUpdate: {
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
                sentTimestamp: TimeInterval(Double(sentTimestampMs) / 1000),
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
    
    private static func handleGroupDeleteMemberContent(
        _ db: Database,
        groupSessionId: SessionId,
        message: GroupUpdateDeleteMemberContentMessage,
        using dependencies: Dependencies
    ) throws {
        guard
            let sentTimestampMs: UInt64 = message.sentTimestamp,
            Authentication.verify(
                signature: message.adminSignature,
                publicKey: groupSessionId.publicKey,
                verificationBytes: GroupUpdateDeleteMemberContentMessage.generateVerificationBytes(
                    memberSessionIds: message.memberSessionIds,
                    timestampMs: sentTimestampMs
                ),
                using: dependencies
            )
        else { throw MessageReceiverError.invalidMessage }
        
        try Interaction
            .filter(
                Interaction.Columns.threadId == groupSessionId.hexString &&
                message.memberSessionIds.asSet().contains(Interaction.Columns.authorId) &&
                Interaction.Columns.timestampMs < sentTimestampMs
            )
            .deleteAll(db)
    }
}
