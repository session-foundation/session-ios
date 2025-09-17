// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionNetworkingKit

extension MessageSender {
    private struct PreparedGroupData {
        let groupSessionId: SessionId
        let identityKeyPair: KeyPair
        let groupState: [ConfigDump.Variant: LibSession.Config]
        let thread: SessionThread
        let group: ClosedGroup
        let members: [GroupMember]
    }
    
    public static func createGroup(
        name: String,
        description: String?,
        displayPictureData: Data?,
        members: [(String, Profile?)],
        using dependencies: Dependencies
    ) -> AnyPublisher<SessionThread, Error> {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let sortedOtherMembers: [(String, Profile?)] = members
            .filter { id, _ in id != userSessionId.hexString }
            .sortedById(userSessionId: userSessionId)
        
        return Just(())
            .setFailureType(to: Error.self)
            .flatMap { _ -> AnyPublisher<DisplayPictureManager.UploadResult?, Error> in
                guard let displayPictureData: Data = displayPictureData else {
                    return Just(nil)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                
                return dependencies[singleton: .displayPictureManager]
                    .prepareAndUploadDisplayPicture(imageData: displayPictureData)
                    .mapError { error -> Error in error }
                    .map { Optional($0) }
                    .eraseToAnyPublisher()
            }
            .flatMapStorageWritePublisher(using: dependencies) { (db: ObservingDatabase, displayPictureInfo: DisplayPictureManager.UploadResult?) -> PreparedGroupData in
                /// Create and cache the libSession entries
                let createdInfo: LibSession.CreatedGroupInfo = try LibSession.createGroup(
                    db,
                    name: name,
                    description: description,
                    displayPictureUrl: displayPictureInfo?.downloadUrl,
                    displayPictureEncryptionKey: displayPictureInfo?.encryptionKey,
                    members: members,
                    using: dependencies
                )
                
                /// Save the relevant objects to the database
                let thread: SessionThread = try SessionThread.upsert(
                    db,
                    id: createdInfo.group.id,
                    variant: .group,
                    values: SessionThread.TargetValues(
                        creationDateTimestamp: .setTo(createdInfo.group.formationTimestamp),
                        shouldBeVisible: .setTo(true)
                    ),
                    using: dependencies
                )
                try createdInfo.group.insert(db)
                try createdInfo.members.forEach { try $0.insert(db) }
                
                /// Add a record of the initial invites going out (default to being read as we don't want the creator of the group
                /// to see the "Unread Messages" banner above this control message)
                _ = try? Interaction(
                    threadId: createdInfo.group.id,
                    threadVariant: .group,
                    authorId: userSessionId.hexString,
                    variant: .infoGroupMembersUpdated,
                    body: ClosedGroup.MessageInfo
                        .addedUsers(
                            hasCurrentUser: false,
                            names: sortedOtherMembers.map { id, profile in
                                profile?.displayName(for: .group) ??
                                id.truncated()
                            },
                            historyShared: false
                        )
                        .infoString(using: dependencies),
                    timestampMs: Int64(createdInfo.group.formationTimestamp * 1000),
                    wasRead: true,
                    using: dependencies
                ).inserted(db)
                
                /// Schedule the "members added" control message to be sent after the config sync completes
                try dependencies[singleton: .jobRunner].add(
                    db,
                    job: Job(
                        variant: .messageSend,
                        behaviour: .runOnceAfterConfigSyncIgnoringPermanentFailure,
                        threadId: createdInfo.group.id,
                        details: MessageSendJob.Details(
                            destination: .closedGroup(groupPublicKey: createdInfo.group.id),
                            message: GroupUpdateMemberChangeMessage(
                                changeType: .added,
                                memberSessionIds: sortedOtherMembers.map { id, _ in id },
                                historyShared: false,
                                sentTimestampMs: UInt64(createdInfo.group.formationTimestamp * 1000),
                                authMethod: Authentication.groupAdmin(
                                    groupSessionId: createdInfo.groupSessionId,
                                    ed25519SecretKey: createdInfo.identityKeyPair.secretKey
                                ),
                                using: dependencies
                            ),
                            requiredConfigSyncVariant: .groupMembers
                        )
                    ),
                    canStartJob: false
                )
                
                return PreparedGroupData(
                    groupSessionId: createdInfo.groupSessionId,
                    identityKeyPair: createdInfo.identityKeyPair,
                    groupState: createdInfo.groupState,
                    thread: thread,
                    group: createdInfo.group,
                    members: createdInfo.members
                )
            }
            .flatMap { preparedGroupData -> AnyPublisher<PreparedGroupData, Error> in
                ConfigurationSyncJob
                    .run(
                        swarmPublicKey: preparedGroupData.groupSessionId.hexString,
                        requireAllRequestsSucceed: true,
                        customAuthMethod: Authentication.groupAdmin(
                            groupSessionId: preparedGroupData.groupSessionId,
                            ed25519SecretKey: preparedGroupData.identityKeyPair.secretKey
                        ),
                        using: dependencies
                    )
                    .flatMap { _ in
                        dependencies[singleton: .storage].writePublisher { db in
                            // Save the successfully created group and add to the user config
                            try LibSession.saveCreatedGroup(
                                db,
                                group: preparedGroupData.group,
                                groupState: preparedGroupData.groupState,
                                using: dependencies
                            )
                            
                            return preparedGroupData
                        }
                    }
                    .handleEvents(
                        receiveCompletion: { result in
                            switch result {
                                case .finished: break
                                case .failure:
                                    // Remove the config and database states
                                    dependencies[singleton: .storage].writeAsync { db in
                                        LibSession.removeGroupStateIfNeeded(
                                            db,
                                            groupSessionId: preparedGroupData.groupSessionId,
                                            using: dependencies
                                        )
                                        
                                        _ = try? preparedGroupData.thread.delete(db)
                                        _ = try? preparedGroupData.group.delete(db)
                                        try? preparedGroupData.members.forEach { try $0.delete(db) }
                                        _ = try? Job
                                            .filter(Job.Columns.threadId == preparedGroupData.group.id)
                                            .deleteAll(db)
                                    }
                            }
                        }
                    )
                    .eraseToAnyPublisher()
            }
            .handleEvents(
                receiveOutput: { preparedGroupData in
                    let userSessionId: SessionId = dependencies[cache: .general].sessionId
                    
                    // Start polling
                    Task.detached(priority: .userInitiated) { [manager = dependencies[singleton: .groupPollerManager]] in
                        await manager.getOrCreatePoller(for: preparedGroupData.thread.id).startIfNeeded()
                    }
                    
                    // Subscribe for push notifications (if PNs are enabled)
                    if let token: String = dependencies[defaults: .standard, key: .deviceToken] {
                        Task.detached(priority: .userInitiated) { [dependencies] in
                            try? await Network.PushNotification.subscribe(
                                token: Data(hex: token),
                                swarmAuthentication: [
                                    try? Authentication.with(
                                        swarmPublicKey: preparedGroupData.groupSessionId.hexString,
                                        using: dependencies
                                    )
                                ].compactMap { $0 },
                                using: dependencies
                            )
                        }
                    }
                    
                    dependencies[singleton: .storage].writeAsync { db in
                        // Save jobs for sending group member invitations
                        preparedGroupData.members
                            .filter { $0.profileId != userSessionId.hexString }
                            .compactMap { member -> (GroupMember, GroupInviteMemberJob.Details)? in
                                // Generate authData for the removed member
                                guard
                                    let memberAuthInfo: Authentication.Info = try? dependencies.mutate(cache: .libSession, { cache in
                                        try dependencies[singleton: .crypto].tryGenerate(
                                            .memberAuthData(
                                                config: cache.config(
                                                    for: .groupKeys,
                                                    sessionId: preparedGroupData.groupSessionId
                                                ),
                                                groupSessionId: preparedGroupData.groupSessionId,
                                                memberId: member.profileId
                                            )
                                        )
                                    }),
                                    let jobDetails: GroupInviteMemberJob.Details = try? GroupInviteMemberJob.Details(
                                        memberSessionIdHexString: member.profileId,
                                        authInfo: memberAuthInfo
                                    )
                                else { return nil }
                                
                                return (member, jobDetails)
                            }
                            .forEach { member, jobDetails in
                                dependencies[singleton: .jobRunner].add(
                                    db,
                                    job: Job(
                                        variant: .groupInviteMember,
                                        threadId: preparedGroupData.thread.id,
                                        details: jobDetails
                                    ),
                                    canStartJob: true
                                )
                            }
                    }
                }
            )
            .map { $0.thread }
            .eraseToAnyPublisher()
    }
    
    public static func updateGroup(
        groupSessionId: String,
        name: String,
        groupDescription: String?,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        guard let sessionId: SessionId = try? SessionId(from: groupSessionId), sessionId.prefix == .group else {
            return Fail(error: MessageSenderError.invalidClosedGroupUpdate).eraseToAnyPublisher()
        }
        
        return dependencies[singleton: .storage]
            .writePublisher { db in
                guard
                    let closedGroup: ClosedGroup = try? ClosedGroup.fetchOne(db, id: sessionId.hexString),
                    let groupIdentityPrivateKey: Data = closedGroup.groupIdentityPrivateKey
                else { throw MessageSenderError.invalidClosedGroupUpdate }
                
                let userSessionId: SessionId = dependencies[cache: .general].sessionId
                let changeTimestampMs: Int64 = dependencies[cache: .storageServer].currentOffsetTimestampMs()
                
                /// Perform the config changes without triggering a config sync (we will trigger one manually as part of the process)
                try dependencies.mutate(cache: .libSession) { cache in
                    try cache.withCustomBehaviour(.skipAutomaticConfigSync, for: sessionId) {
                        var groupChanges: [ConfigColumnAssignment] = []
                        
                        if name != closedGroup.name {
                            groupChanges.append(ClosedGroup.Columns.name.set(to: name))
                            db.addConversationEvent(id: groupSessionId, type: .updated(.displayName(name)))
                        }
                        if groupDescription != closedGroup.groupDescription {
                            groupChanges.append(ClosedGroup.Columns.groupDescription.set(to: groupDescription))
                            db.addConversationEvent(
                                id: groupSessionId,
                                type: .updated(.description(groupDescription))
                            )
                        }
                        
                        /// Update the group (this will be propagated to libSession configs automatically)
                        if !groupChanges.isEmpty {
                            _ = try ClosedGroup
                                .filter(id: sessionId.hexString)
                                .updateAllAndConfig(
                                    db,
                                    ClosedGroup.Columns.name.set(to: name),
                                    ClosedGroup.Columns.groupDescription.set(to: groupDescription),
                                    using: dependencies
                                )
                        }
                    }
                }
                
                /// Add a record of the name change to the conversation
                if name != closedGroup.name {
                    let disappearingConfig: DisappearingMessagesConfiguration? = try? DisappearingMessagesConfiguration.fetchOne(db, id: sessionId.hexString)
                    
                    _ = try Interaction(
                        threadId: groupSessionId,
                        threadVariant: .group,
                        authorId: userSessionId.hexString,
                        variant: .infoGroupInfoUpdated,
                        body: ClosedGroup.MessageInfo
                            .updatedName(name)
                            .infoString(using: dependencies),
                        timestampMs: changeTimestampMs,
                        expiresInSeconds: disappearingConfig?.expiresInSeconds(),
                        expiresStartedAtMs: disappearingConfig?.initialExpiresStartedAtMs(
                            sentTimestampMs: Double(changeTimestampMs)
                        ),
                        using: dependencies
                    ).inserted(db)
                    
                    /// Schedule the control message to be sent to the group after the config sync completes
                    try dependencies[singleton: .jobRunner].add(
                        db,
                        job: Job(
                            variant: .messageSend,
                            behaviour: .runOnceAfterConfigSyncIgnoringPermanentFailure,
                            threadId: sessionId.hexString,
                            details: MessageSendJob.Details(
                                destination: .closedGroup(groupPublicKey: sessionId.hexString),
                                message: GroupUpdateInfoChangeMessage(
                                    changeType: .name,
                                    updatedName: name,
                                    sentTimestampMs: UInt64(changeTimestampMs),
                                    authMethod: Authentication.groupAdmin(
                                        groupSessionId: sessionId,
                                        ed25519SecretKey: Array(groupIdentityPrivateKey)
                                    ),
                                    using: dependencies
                                ).with(disappearingConfig),
                                requiredConfigSyncVariant: .groupInfo
                            )
                        ),
                        canStartJob: false
                    )
                }
            }
            .flatMap { _ -> AnyPublisher<Void, Error> in
                ConfigurationSyncJob
                    .run(swarmPublicKey: groupSessionId, using: dependencies)
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    
    public static func updateGroup(
        groupSessionId: String,
        displayPictureUpdate: DisplayPictureManager.Update,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        guard let sessionId: SessionId = try? SessionId(from: groupSessionId), sessionId.prefix == .group else {
            return Fail(error: MessageSenderError.invalidClosedGroupUpdate).eraseToAnyPublisher()
        }
        
        return dependencies[singleton: .storage]
            .writePublisher { db in
                guard
                    let groupIdentityPrivateKey: Data = try? ClosedGroup
                        .filter(id: sessionId.hexString)
                        .select(.groupIdentityPrivateKey)
                        .asRequest(of: Data.self)
                        .fetchOne(db)
                else { throw MessageSenderError.invalidClosedGroupUpdate }
                
                let userSessionId: SessionId = dependencies[cache: .general].sessionId
                let changeTimestampMs: Int64 = dependencies[cache: .storageServer].currentOffsetTimestampMs()
                
                /// Perform the config changes without triggering a config sync (we will trigger one manually as part of the process)
                try dependencies.mutate(cache: .libSession) { cache in
                    try cache.withCustomBehaviour(.skipAutomaticConfigSync, for: sessionId) {
                        switch displayPictureUpdate {
                            case .groupRemove:
                                try ClosedGroup
                                    .filter(id: groupSessionId)
                                    .updateAllAndConfig(
                                        db,
                                        ClosedGroup.Columns.displayPictureUrl.set(to: nil),
                                        ClosedGroup.Columns.displayPictureEncryptionKey.set(to: nil),
                                        using: dependencies
                                    )
                                
                            case .groupUpdateTo(let url, let key, _):
                                try ClosedGroup
                                    .filter(id: groupSessionId)
                                    .updateAllAndConfig(
                                        db,
                                        ClosedGroup.Columns.displayPictureUrl.set(to: url),
                                        ClosedGroup.Columns.displayPictureEncryptionKey.set(to: key),
                                        using: dependencies
                                    )
                                
                            default: throw MessageSenderError.invalidClosedGroupUpdate
                        }
                    }
                }
                
                let disappearingConfig: DisappearingMessagesConfiguration? = try? DisappearingMessagesConfiguration.fetchOne(db, id: sessionId.hexString)
                
                /// Add a record of the change to the conversation
                _ = try Interaction(
                    threadId: groupSessionId,
                    threadVariant: .group,
                    authorId: userSessionId.hexString,
                    variant: .infoGroupInfoUpdated,
                    body: ClosedGroup.MessageInfo
                        .updatedDisplayPicture
                        .infoString(using: dependencies),
                    timestampMs: changeTimestampMs,
                    expiresInSeconds: disappearingConfig?.expiresInSeconds(),
                    expiresStartedAtMs: disappearingConfig?.initialExpiresStartedAtMs(
                        sentTimestampMs: Double(changeTimestampMs)
                    ),
                    using: dependencies
                ).inserted(db)
                
                /// Schedule the control message to be sent to the group after the config sync completes
                try dependencies[singleton: .jobRunner].add(
                    db,
                    job: Job(
                        variant: .messageSend,
                        behaviour: .runOnceAfterConfigSyncIgnoringPermanentFailure,
                        threadId: sessionId.hexString,
                        details: MessageSendJob.Details(
                            destination: .closedGroup(groupPublicKey: sessionId.hexString),
                            message: GroupUpdateInfoChangeMessage(
                                changeType: .avatar,
                                sentTimestampMs: UInt64(changeTimestampMs),
                                authMethod: Authentication.groupAdmin(
                                    groupSessionId: sessionId,
                                    ed25519SecretKey: Array(groupIdentityPrivateKey)
                                ),
                                using: dependencies
                            ).with(disappearingConfig),
                            requiredConfigSyncVariant: .groupInfo
                        )
                    ),
                    canStartJob: false
                )
            }
            .flatMap { _ -> AnyPublisher<Void, Error> in
                ConfigurationSyncJob
                    .run(swarmPublicKey: groupSessionId, using: dependencies)
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    
    public static func updateGroup(
        groupSessionId: String,
        disapperingMessagesConfig updatedConfig: DisappearingMessagesConfiguration,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        guard let sessionId: SessionId = try? SessionId(from: groupSessionId), sessionId.prefix == .group else {
            return Fail(error: MessageSenderError.invalidClosedGroupUpdate).eraseToAnyPublisher()
        }
        
        return dependencies[singleton: .storage]
            .writePublisher { db in
                guard
                    let groupIdentityPrivateKey: Data = try? ClosedGroup
                        .filter(id: sessionId.hexString)
                        .select(.groupIdentityPrivateKey)
                        .asRequest(of: Data.self)
                        .fetchOne(db)
                else { throw MessageSenderError.invalidClosedGroupUpdate }
                
                let currentOffsetTimestampMs: Int64 = dependencies[cache: .storageServer].currentOffsetTimestampMs()
            
                /// Perform the config changes without triggering a config sync (we will trigger one manually as part of the process)
                try dependencies.mutate(cache: .libSession) { cache in
                    try cache.withCustomBehaviour(.skipAutomaticConfigSync, for: sessionId) {
                        /// Update the local state
                        try updatedConfig.upserted(db)
                        
                        /// Add a record of the change to the conversation
                        _ = try updatedConfig
                            .upserted(db)
                            .insertControlMessage(
                                db,
                                threadVariant: .group,
                                authorId: dependencies[cache: .general].sessionId.hexString,
                                timestampMs: currentOffsetTimestampMs,
                                serverHash: nil,
                                serverExpirationTimestamp: nil,
                                using: dependencies
                            )
                        
                        /// Update the libSession state
                        try LibSession.update(
                            db,
                            groupSessionId: sessionId,
                            disappearingConfig: updatedConfig,
                            using: dependencies
                        )
                    }
                }
                
                /// Schedule the control message to be sent to the group after the config sync completes
                try dependencies[singleton: .jobRunner].add(
                    db,
                    job: Job(
                        variant: .messageSend,
                        behaviour: .runOnceAfterConfigSyncIgnoringPermanentFailure,
                        threadId: sessionId.hexString,
                        details: MessageSendJob.Details(
                            destination: .closedGroup(groupPublicKey: sessionId.hexString),
                            message: GroupUpdateInfoChangeMessage(
                                changeType: .disappearingMessages,
                                updatedExpiration: UInt32(updatedConfig.isEnabled ?
                                    updatedConfig.durationSeconds :
                                    0
                                ),
                                sentTimestampMs: UInt64(currentOffsetTimestampMs),
                                authMethod: Authentication.groupAdmin(
                                    groupSessionId: sessionId,
                                    ed25519SecretKey: Array(groupIdentityPrivateKey)
                                ),
                                using: dependencies
                            ),
                            requiredConfigSyncVariant: .groupInfo
                        )
                    ),
                    canStartJob: false
                )
            }
            .flatMap { _ -> AnyPublisher<Void, Error> in
                ConfigurationSyncJob
                    .run(swarmPublicKey: groupSessionId, using: dependencies)
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    
    public static func addGroupMembers(
        groupSessionId: String,
        members: [(String, Profile?)],
        allowAccessToHistoricMessages: Bool,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        guard let sessionId: SessionId = try? SessionId(from: groupSessionId), sessionId.prefix == .group else {
            return Fail(error: MessageSenderError.invalidClosedGroupUpdate).eraseToAnyPublisher()
        }
        
        typealias MemberJobData = (
            id: String,
            profile: Profile?,
            jobDetails: GroupInviteMemberJob.Details,
            subaccountToken: [UInt8]
        )
        
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let sortedMembers: [(String, Profile?)] = members
            .sortedById(userSessionId: userSessionId)
        
        return dependencies[singleton: .storage]
            .writePublisher { db -> ([MemberJobData], Network.PreparedRequest<Void>, Network.PreparedRequest<Void>?) in
                guard
                    let groupIdentityPrivateKey: Data = try? ClosedGroup
                        .filter(id: sessionId.hexString)
                        .select(.groupIdentityPrivateKey)
                        .asRequest(of: Data.self)
                        .fetchOne(db)
                else { throw MessageSenderError.invalidClosedGroupUpdate }
                
                let changeTimestampMs: Int64 = dependencies[cache: .storageServer].currentOffsetTimestampMs()
                var maybeSupplementalKeyRequest: Network.PreparedRequest<Void>?
                
                /// Perform the config changes without triggering a config sync (we will trigger one manually as part of the process)
                try dependencies.mutate(cache: .libSession) { cache in
                    try cache.withCustomBehaviour(.skipAutomaticConfigSync, for: sessionId) {
                        /// Add the members to the `GROUP_MEMBERS` config
                        try LibSession.addMembers(
                            db,
                            groupSessionId: sessionId,
                            members: members,
                            allowAccessToHistoricMessages: allowAccessToHistoricMessages,
                            using: dependencies
                        )
                        
                        /// If we want to grant access to historic messages then we need to generate a supplemental keys message,
                        /// since our state doesn't care about the `GROUP_KEYS` needed for other members triggering a `keySupplement`
                        /// change won't result in the `GROUP_KEYS` config changing so we need to push the change directly
                        if allowAccessToHistoricMessages {
                            let supplementData: Data = try LibSession.keySupplement(
                                db,
                                groupSessionId: sessionId,
                                memberIds: members.map { id, _ in id }.asSet(),
                                using: dependencies
                            )
                            
                            maybeSupplementalKeyRequest = try Network.StorageServer.preparedSendMessage(
                                request: Network.StorageServer.SendMessageRequest(
                                    recipient: sessionId.hexString,
                                    namespace: .configGroupKeys,
                                    data: supplementData,
                                    ttl: ConfigDump.Variant.groupKeys.ttl,
                                    timestampMs: UInt64(changeTimestampMs),
                                    authMethod: Authentication.groupAdmin(
                                        groupSessionId: sessionId,
                                        ed25519SecretKey: Array(groupIdentityPrivateKey)
                                    )
                                ),
                                using: dependencies
                            )
                            .map { _, _ in () }
                        }
                        
                        /// Since we have added new members we need to perform a `rekey` so that all new messages get
                        /// encrypted using new keys and the `GROUP_KEYS` `seqNo` is increased
                        ///
                        /// **Note:** This **MUST** be called _after_ the new members have been added to the group, otherwise the
                        /// keys may not be generated correctly for the newly added members
                        ///
                        /// **Note 2:** This **MUST** be done even when peforming a `keySupplement` because if the member
                        /// with supplemental access was kicked from the group during the current key rotation then the kicked message
                        /// would still be valid due to the `seqNo` and the member's device would consider the member kicked (we also
                        /// do this after doing the `keySupplement` as otherwise the new key would be needlessly included in the
                        /// `keySupplement` message)
                        try LibSession.rekey(
                            db,
                            groupSessionId: sessionId,
                            using: dependencies
                        )
                        
                        /// Since we have added them to `GROUP_MEMBERS` we may as well insert them into the database (even if the request
                        /// fails the local state will have already been updated anyway)
                        ///
                        /// Add them in the `sending` state so the UI is in the correct state immediately
                        members.forEach { id, _ in
                            /// Add the member to the database
                            try? GroupMember(
                                groupId: sessionId.hexString,
                                profileId: id,
                                role: .standard,
                                roleStatus: .sending,
                                isHidden: false
                            ).upsert(db)
                        }
                    }
                }
                
                /// Generate the data needed to send the new members invitations to the group
                let memberJobData: [MemberJobData] = (try? members
                    .map { id, profile in
                        // Generate authData for the newly added member
                        let memberInfo: (token: [UInt8], details: GroupInviteMemberJob.Details) = try dependencies.mutate(cache: .libSession) { cache in
                            return (
                                try dependencies[singleton: .crypto].tryGenerate(
                                    .tokenSubaccount(
                                        config: cache.config(for: .groupKeys, sessionId: sessionId),
                                        groupSessionId: sessionId,
                                        memberId: id
                                    )
                                ),
                                try GroupInviteMemberJob.Details(
                                    memberSessionIdHexString: id,
                                    authInfo: try dependencies[singleton: .crypto].tryGenerate(
                                        .memberAuthData(
                                            config: cache.config(for: .groupKeys, sessionId: sessionId),
                                            groupSessionId: sessionId,
                                            memberId: id
                                        )
                                    )
                                )
                            )
                        }
                        
                        return (id, profile, memberInfo.details, memberInfo.token)
                    })
                    .defaulting(to: [])
                    
                /// Unrevoke the newly added members just in case they had previously gotten their access to the group
                /// revoked (fire-and-forget this request, we don't want it to be blocking - if the invited user still can't access
                /// the group the admin can resend their invitation which will also attempt to unrevoke their subaccount)
                let unrevokeRequest: Network.PreparedRequest<Void> = try Network.StorageServer.preparedUnrevokeSubaccounts(
                    subaccountsToUnrevoke: memberJobData.map { _, _, _, subaccountToken in subaccountToken },
                    authMethod: Authentication.groupAdmin(
                        groupSessionId: sessionId,
                        ed25519SecretKey: Array(groupIdentityPrivateKey)
                    ),
                    using: dependencies
                )
                
                /// Add a record of the change to the conversation
                let disappearingConfig: DisappearingMessagesConfiguration? = try? DisappearingMessagesConfiguration.fetchOne(db, id: sessionId.hexString)
                
                _ = try? Interaction(
                    threadId: groupSessionId,
                    threadVariant: .group,
                    authorId: userSessionId.hexString,
                    variant: .infoGroupMembersUpdated,
                    body: ClosedGroup.MessageInfo
                        .addedUsers(
                            hasCurrentUser: members.contains { id, _ in id == userSessionId.hexString },
                            names: sortedMembers.map { id, profile in
                                profile?.displayName(for: .group) ??
                                id.truncated()
                            },
                            historyShared: allowAccessToHistoricMessages
                        )
                        .infoString(using: dependencies),
                    timestampMs: changeTimestampMs,
                    expiresInSeconds: disappearingConfig?.expiresInSeconds(),
                    expiresStartedAtMs: disappearingConfig?.initialExpiresStartedAtMs(
                        sentTimestampMs: Double(changeTimestampMs)
                    ),
                    using: dependencies
                ).inserted(db)
                
                /// Schedule the control message to be sent to the group after the config sync completes
                try dependencies[singleton: .jobRunner].add(
                    db,
                    job: Job(
                        variant: .messageSend,
                        behaviour: .runOnceAfterConfigSyncIgnoringPermanentFailure,
                        threadId: sessionId.hexString,
                        details: MessageSendJob.Details(
                            destination: .closedGroup(groupPublicKey: sessionId.hexString),
                            message: GroupUpdateMemberChangeMessage(
                                changeType: .added,
                                memberSessionIds: sortedMembers.map { id, _ in id },
                                historyShared: allowAccessToHistoricMessages,
                                sentTimestampMs: UInt64(changeTimestampMs),
                                authMethod: Authentication.groupAdmin(
                                    groupSessionId: sessionId,
                                    ed25519SecretKey: Array(groupIdentityPrivateKey)
                                ),
                                using: dependencies
                            ).with(try? DisappearingMessagesConfiguration.fetchOne(db, id: sessionId.hexString)),
                            requiredConfigSyncVariant: .groupMembers
                        )
                    ),
                    canStartJob: false
                )
                
                return (memberJobData, unrevokeRequest, maybeSupplementalKeyRequest)
            }
            .flatMap { memberJobData, unrevokeRequest, maybeSupplementalKeyRequest -> AnyPublisher<[MemberJobData], Error> in
                ConfigurationSyncJob
                    .run(
                        swarmPublicKey: sessionId.hexString,
                        beforeSequenceRequests: [unrevokeRequest, maybeSupplementalKeyRequest].compactMap { $0 },
                        requireAllBatchResponses: true,
                        requireAllRequestsSucceed: true,
                        using: dependencies
                    )
                    .map { _ in memberJobData }
                    .eraseToAnyPublisher()
            }
            .handleEvents(
                receiveOutput: { memberJobData in
                    /// Schedule jobs to send invitations to the newly added members
                    ///
                    /// **Note:** We intentionally don't schedule these as `runOnceAfterConfigSyncIgnoringPermanentFailure`
                    /// because if the above request fails then it's possible a required `keySupplement` message wasn't sent (in which case
                    /// we want an andmin to manually trigger a resend, which would generate and send a new `keySupplement` message)
                    dependencies[singleton: .storage].writeAsync { db in
                        memberJobData.forEach { id, profile, inviteJobDetails, _ in
                            dependencies[singleton: .jobRunner].add(
                                db,
                                job: Job(
                                    variant: .groupInviteMember,
                                    threadId: sessionId.hexString,
                                    details: inviteJobDetails
                                ),
                                canStartJob: true
                            )
                        }
                    }
                }
            )
            .map { _ in () }
            .eraseToAnyPublisher()
    }
    
    public static func resendInvitations(
        groupSessionId: String,
        memberIds: [String],
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        guard let sessionId: SessionId = try? SessionId(from: groupSessionId), sessionId.prefix == .group else {
            return Fail(error: MessageSenderError.invalidClosedGroupUpdate).eraseToAnyPublisher()
        }
        
        return dependencies[singleton: .storage]
            .writePublisher { db -> ([GroupInviteMemberJob.Details], Network.PreparedRequest<Void>, Network.PreparedRequest<Void>?) in
                guard
                    let groupIdentityPrivateKey: Data = try? ClosedGroup
                        .filter(id: groupSessionId)
                        .select(.groupIdentityPrivateKey)
                        .asRequest(of: Data.self)
                        .fetchOne(db)
                else { throw MessageSenderError.invalidClosedGroupUpdate }
                
                let changeTimestampMs: Int64 = dependencies[cache: .storageServer].currentOffsetTimestampMs()
                var maybeSupplementalKeyRequest: Network.PreparedRequest<Void>?
                
                /// Perform the config changes without triggering a config sync (we will do so manually after the process completes)
                try dependencies.mutate(cache: .libSession) { cache in
                    try cache.withCustomBehaviour(.skipAutomaticConfigSync, for: sessionId) {
                        try memberIds.forEach { memberId in
                            try LibSession.updateMemberStatus(
                                db,
                                groupSessionId: SessionId(.group, hex: groupSessionId),
                                memberId: memberId,
                                role: .standard,
                                status: .sending,
                                profile: nil,
                                using: dependencies
                            )
                            
                            /// If the current `GroupMember` isn't already in the `sending` state then update them to be in it
                            let memberStatus: GroupMember.RoleStatus? = try GroupMember
                                .select(.roleStatus)
                                .filter(GroupMember.Columns.groupId == groupSessionId)
                                .filter(GroupMember.Columns.profileId == memberId)
                                .asRequest(of: GroupMember.RoleStatus.self)
                                .fetchOne(db)
                            
                            if memberStatus != .sending {
                                try GroupMember
                                    .filter(GroupMember.Columns.groupId == groupSessionId)
                                    .filter(GroupMember.Columns.profileId == memberId)
                                    .updateAllAndConfig(
                                        db,
                                        GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.sending),
                                        using: dependencies
                                    )
                            }
                        }
                        
                        /// If any of the members are flagged as `supplement` then it means we _should_ have sent a
                        /// supplemental keys message when initially inviting them **but** if that initial request failed then
                        /// the supplemental keys message may not have been sent (since it's not persistent to the `GROUP_KEYS`
                        /// state this message not existing would result in the member being unable to read old messages) - to
                        /// handle this case we create a new supplemental keys rotation for those members and try to send it again
                        let supplementalRotationMemberIds: [String] = memberIds
                            .filter {
                                LibSession.isSupplementalMember(
                                    groupSessionId: sessionId,
                                    memberId: $0,
                                    using: dependencies
                                )
                            }
                        
                        if !supplementalRotationMemberIds.isEmpty {
                            let supplementData: Data = try LibSession.keySupplement(
                                db,
                                groupSessionId: sessionId,
                                memberIds: Set(supplementalRotationMemberIds),
                                using: dependencies
                            )
                            
                            maybeSupplementalKeyRequest = try Network.StorageServer.preparedSendMessage(
                                request: Network.StorageServer.SendMessageRequest(
                                    recipient: sessionId.hexString,
                                    namespace: .configGroupKeys,
                                    data: supplementData,
                                    ttl: ConfigDump.Variant.groupKeys.ttl,
                                    timestampMs: UInt64(changeTimestampMs),
                                    authMethod: Authentication.groupAdmin(
                                        groupSessionId: sessionId,
                                        ed25519SecretKey: Array(groupIdentityPrivateKey)
                                    )
                                ),
                                using: dependencies
                            )
                            .map { _, _ in () }
                        }
                    }
                }
                
                let memberInfo: [(token: [UInt8], details: GroupInviteMemberJob.Details)] = try memberIds
                    .map { memberId in
                        try dependencies.mutate(cache: .libSession) { cache in
                            return (
                                try dependencies[singleton: .crypto].tryGenerate(
                                    .tokenSubaccount(
                                        config: cache.config(for: .groupKeys, sessionId: sessionId),
                                        groupSessionId: sessionId,
                                        memberId: memberId
                                    )
                                ),
                                try GroupInviteMemberJob.Details(
                                    memberSessionIdHexString: memberId,
                                    authInfo: try dependencies[singleton: .crypto].tryGenerate(
                                        .memberAuthData(
                                            config: cache.config(for: .groupKeys, sessionId: sessionId),
                                            groupSessionId: sessionId,
                                            memberId: memberId
                                        )
                                    )
                                )
                            )
                        }
                    }
                
                /// Unrevoke the member just in case they had previously gotten their access to the group revoked and the
                /// unrevoke request when initially added them failed (fire-and-forget this request, we don't want it to be blocking)
                let unrevokeRequest: Network.PreparedRequest<Void> = try Network.StorageServer
                    .preparedUnrevokeSubaccounts(
                        subaccountsToUnrevoke: memberInfo.map { token, _ in token },
                        authMethod: Authentication.groupAdmin(
                            groupSessionId: sessionId,
                            ed25519SecretKey: Array(groupIdentityPrivateKey)
                        ),
                        using: dependencies
                    )
                
                return (memberInfo.map { _, jobDetails in jobDetails }, unrevokeRequest, maybeSupplementalKeyRequest)
            }
            .flatMap { memberJobData, unrevokeRequest, maybeSupplementalKeyRequest -> AnyPublisher<[GroupInviteMemberJob.Details], Error> in
                ConfigurationSyncJob
                    .run(
                        swarmPublicKey: sessionId.hexString,
                        beforeSequenceRequests: [unrevokeRequest, maybeSupplementalKeyRequest].compactMap { $0 },
                        requireAllBatchResponses: true,
                        requireAllRequestsSucceed: true,
                        using: dependencies
                    )
                    .map { _ in memberJobData }
                    .eraseToAnyPublisher()
            }
            .handleEvents(
                receiveOutput: { memberJobData in
                    /// Schedule a job to send an invitation to the member
                    dependencies[singleton: .storage].writeAsync { db in
                        memberJobData.forEach { details in
                            dependencies[singleton: .jobRunner].add(
                                db,
                                job: Job(
                                    variant: .groupInviteMember,
                                    threadId: sessionId.hexString,
                                    details: details
                                ),
                                canStartJob: true
                            )
                        }
                    }
                }
            )
            .map { _ in () }
            .eraseToAnyPublisher()
    }
    
    public static func removeGroupMembers(
        groupSessionId: String,
        memberIds: Set<String>,
        removeTheirMessages: Bool,
        sendMemberChangedMessage: Bool,
        changeTimestampMs: Int64? = nil,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        guard let sessionId: SessionId = try? SessionId(from: groupSessionId), sessionId.prefix == .group else {
            return Just(()).setFailureType(to: Error.self).eraseToAnyPublisher()
        }
        
        let targetChangeTimestampMs: Int64 = (
            changeTimestampMs ??
            dependencies[cache: .storageServer].currentOffsetTimestampMs()
        )
        
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let sortedMemberIds: [String] = memberIds.sortedById(userSessionId: userSessionId)
        
        return dependencies[singleton: .storage]
            .writePublisher { db in
                guard
                    let groupIdentityPrivateKey: Data = try? ClosedGroup
                        .filter(id: sessionId.hexString)
                        .select(.groupIdentityPrivateKey)
                        .asRequest(of: Data.self)
                        .fetchOne(db)
                else { throw MessageSenderError.invalidClosedGroupUpdate }
                
                /// Perform the config changes without triggering a config sync (we will do so manually after the process completes)
                try dependencies.mutate(cache: .libSession) { cache in
                    try cache.withCustomBehaviour(.skipAutomaticConfigSync, for: sessionId) {
                        /// Flag the members for removal
                        try LibSession.flagMembersForRemoval(
                            db,
                            groupSessionId: sessionId,
                            memberIds: memberIds,
                            removeMessages: removeTheirMessages,
                            using: dependencies
                        )
                        
                        /// Flag  the members in the database as "pending removal" (will result in the UI being updated)
                        try GroupMember
                            .filter(GroupMember.Columns.groupId == sessionId.hexString)
                            .filter(memberIds.contains(GroupMember.Columns.profileId))
                            .updateAllAndConfig(
                                db,
                                GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.pendingRemoval),
                                using: dependencies
                            )
                    }
                }
                
                /// Schedule a job to process the removals
                dependencies[singleton: .jobRunner].add(
                    db,
                    job: Job(
                        variant: .processPendingGroupMemberRemovals,
                        threadId: sessionId.hexString,
                        details: ProcessPendingGroupMemberRemovalsJob.Details(
                            changeTimestampMs: changeTimestampMs
                        )
                    ),
                    canStartJob: true
                )
                
                /// Send the member changed message if desired
                if sendMemberChangedMessage {
                    let removedMemberProfiles: [String: Profile] = (try? Profile
                        .filter(ids: memberIds)
                        .fetchAll(db))
                        .defaulting(to: [])
                        .reduce(into: [:]) { result, next in result[next.id] = next }
                    let disappearingConfig: DisappearingMessagesConfiguration? = try? DisappearingMessagesConfiguration.fetchOne(db, id: sessionId.hexString)
                    
                    /// Add a record of the change to the conversation
                    _ = try Interaction(
                        threadId: sessionId.hexString,
                        threadVariant: .group,
                        authorId: userSessionId.hexString,
                        variant: .infoGroupMembersUpdated,
                        body: ClosedGroup.MessageInfo
                            .removedUsers(
                                hasCurrentUser: memberIds.contains(userSessionId.hexString),
                                names: sortedMemberIds.map { id in
                                    removedMemberProfiles[id]?.displayName(for: .group) ??
                                    id.truncated()
                                }
                            )
                            .infoString(using: dependencies),
                        timestampMs: targetChangeTimestampMs,
                        expiresInSeconds: disappearingConfig?.expiresInSeconds(),
                        expiresStartedAtMs: disappearingConfig?.initialExpiresStartedAtMs(
                            sentTimestampMs: Double(targetChangeTimestampMs)
                        ),
                        using: dependencies
                    ).inserted(db)
                    
                    /// Schedule the control message to be sent to the group after the config sync completes
                    try dependencies[singleton: .jobRunner].add(
                        db,
                        job: Job(
                            variant: .messageSend,
                            behaviour: .runOnceAfterConfigSyncIgnoringPermanentFailure,
                            threadId: sessionId.hexString,
                            details: MessageSendJob.Details(
                                destination: .closedGroup(groupPublicKey: sessionId.hexString),
                                message: GroupUpdateMemberChangeMessage(
                                    changeType: .removed,
                                    memberSessionIds: sortedMemberIds,
                                    historyShared: false,
                                    sentTimestampMs: UInt64(targetChangeTimestampMs),
                                    authMethod: Authentication.groupAdmin(
                                        groupSessionId: sessionId,
                                        ed25519SecretKey: Array(groupIdentityPrivateKey)
                                    ),
                                    using: dependencies
                                ).with(disappearingConfig),
                                requiredConfigSyncVariant: .groupMembers
                            )
                        ),
                        canStartJob: false
                    )
                }
            }
            .flatMap { _ -> AnyPublisher<Void, Error> in
                ConfigurationSyncJob
                    .run(swarmPublicKey: groupSessionId, using: dependencies)
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
    
    public static func promoteGroupMembers(
        groupSessionId: SessionId,
        members: [(String, Profile?)],
        isResend: Bool,
        using dependencies: Dependencies
    ) -> AnyPublisher<Void, Error> {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        
        return dependencies[singleton: .storage]
            .writePublisher { db -> Set<String> in
                guard
                    let groupIdentityPrivateKey: Data = try? ClosedGroup
                        .filter(id: groupSessionId.hexString)
                        .select(.groupIdentityPrivateKey)
                        .asRequest(of: Data.self)
                        .fetchOne(db)
                else { throw MessageSenderError.invalidClosedGroupUpdate }
            
                /// Determine which members actually need to be promoted (rather than just resent promotions)
                let memberIds: Set<String> = Set(members.map { id, _ in id })
                let memberIdsRequiringPromotions: Set<String> = try GroupMember
                    .select(.profileId)
                    .filter(GroupMember.Columns.groupId == groupSessionId.hexString)
                    .filter(memberIds.contains(GroupMember.Columns.profileId))
                    .filter(GroupMember.Columns.role == GroupMember.Role.standard)
                    .asRequest(of: String.self)
                    .fetchSet(db)
                let membersReceivingPromotions: [(String, Profile?)] = members
                    .filter { id, _ in memberIdsRequiringPromotions.contains(id) }
                let sortedMembersReceivingPromotions: [(String, Profile?)] = membersReceivingPromotions
                    .sortedById(userSessionId: userSessionId)
                
                /// Perform the config changes without triggering a config sync (we will do so manually after the process completes)
                try dependencies.mutate(cache: .libSession) { cache in
                    try cache.withCustomBehaviour(.skipAutomaticConfigSync, for: groupSessionId) {
                        try members.forEach { memberId, profile in
                            try LibSession.updateMemberStatus(
                                db,
                                groupSessionId: groupSessionId,
                                memberId: memberId,
                                role: .admin,
                                status: .sending,
                                profile: nil,
                                using: dependencies
                            )
                        }
                        
                        /// Update failed admins to be sending
                        try GroupMember
                            .filter(GroupMember.Columns.groupId == groupSessionId.hexString)
                            .filter(memberIds.contains(GroupMember.Columns.profileId))
                            .filter(GroupMember.Columns.role == GroupMember.Role.admin)
                            .updateAllAndConfig(
                                db,
                                GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.sending),
                                using: dependencies
                            )
                        
                        /// Update standard members to be admins
                        try GroupMember
                            .filter(GroupMember.Columns.groupId == groupSessionId.hexString)
                            .filter(memberIds.contains(GroupMember.Columns.profileId))
                            .filter(GroupMember.Columns.role == GroupMember.Role.standard)
                            .updateAllAndConfig(
                                db,
                                GroupMember.Columns.role.set(to: GroupMember.Role.admin),
                                GroupMember.Columns.roleStatus.set(to: GroupMember.RoleStatus.sending),
                                using: dependencies
                            )
                    }
                }
                
                /// Send the admin changed message if desired
                ///
                /// If this is a retry then there is no need to add a record of the change to the conversation (as we would have
                /// added it during the first attempt)
                ///
                /// **Note:** It's possible that this call could contain both members being promoted as well as admins
                /// that are getting promotions re-sent to them - we only want to send an admin changed message if there
                /// is a newly promoted member
                if !isResend && !membersReceivingPromotions.isEmpty {
                    let changeTimestampMs: Int64 = dependencies[cache: .storageServer].currentOffsetTimestampMs()
                    let disappearingConfig: DisappearingMessagesConfiguration? = try? DisappearingMessagesConfiguration.fetchOne(db, id: groupSessionId.hexString)
                    
                    _ = try Interaction(
                        threadId: groupSessionId.hexString,
                        threadVariant: .group,
                        authorId: userSessionId.hexString,
                        variant: .infoGroupMembersUpdated,
                        body: ClosedGroup.MessageInfo
                            .promotedUsers(
                                hasCurrentUser: membersReceivingPromotions
                                    .map { id, _ in id }
                                    .contains(userSessionId.hexString),
                                names: sortedMembersReceivingPromotions.map { id, profile in
                                    profile?.displayName(for: .group) ??
                                    id.truncated()
                                }
                            )
                            .infoString(using: dependencies),
                        timestampMs: changeTimestampMs,
                        expiresInSeconds: disappearingConfig?.expiresInSeconds(),
                        expiresStartedAtMs: disappearingConfig?.initialExpiresStartedAtMs(
                            sentTimestampMs: Double(changeTimestampMs)
                        ),
                        using: dependencies
                    ).inserted(db)
                    
                    /// Schedule the control message to be sent to the group after the config sync completes
                    try dependencies[singleton: .jobRunner].add(
                        db,
                        job: Job(
                            variant: .messageSend,
                            behaviour: .runOnceAfterConfigSyncIgnoringPermanentFailure,
                            threadId: groupSessionId.hexString,
                            details: MessageSendJob.Details(
                                destination: .closedGroup(groupPublicKey: groupSessionId.hexString),
                                message: GroupUpdateMemberChangeMessage(
                                    changeType: .promoted,
                                    memberSessionIds: sortedMembersReceivingPromotions.map { id, _ in id },
                                    historyShared: false,
                                    sentTimestampMs: UInt64(changeTimestampMs),
                                    authMethod: Authentication.groupAdmin(
                                        groupSessionId: groupSessionId,
                                        ed25519SecretKey: Array(groupIdentityPrivateKey)
                                    ),
                                    using: dependencies
                                ).with(disappearingConfig),
                                requiredConfigSyncVariant: .groupMembers
                            )
                        ),
                        canStartJob: false
                    )
                }
                
                return memberIds
            }
            .flatMap { memberIds -> AnyPublisher<Set<String>, Error> in
                ConfigurationSyncJob
                    .run(swarmPublicKey: groupSessionId.hexString, using: dependencies)
                    .map { _ in memberIds }
                    .eraseToAnyPublisher()
            }
            .handleEvents(
                receiveOutput: { memberIds in
                    dependencies[singleton: .storage].writeAsync { db in
                        /// Schedule jobs to send promotions to all members (including previously promoted members)
                        memberIds.forEach { id in
                            dependencies[singleton: .jobRunner].add(
                                db,
                                job: Job(
                                    variant: .groupPromoteMember,
                                    threadId: groupSessionId.hexString,
                                    details: GroupPromoteMemberJob.Details(
                                        memberSessionIdHexString: id
                                    )
                                ),
                                canStartJob: true
                            )
                        }
                    }
                }
            )
            .map { _ in () }
            .eraseToAnyPublisher()
    }
    
    /// Leave the group with the given `groupPublicKey`. If the current user is the only admin, the group is disbanded entirely.
    ///
    /// This function also removes all encryption key pairs associated with the closed group and the group's public key, and
    /// unregisters from push notifications.
    public static func leave(
        _ db: ObservingDatabase,
        threadId: String,
        threadVariant: SessionThread.Variant,
        using dependencies: Dependencies
    ) throws {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        
        // Notify the user
        let interaction: Interaction = try Interaction(
            threadId: threadId,
            threadVariant: threadVariant,
            authorId: userSessionId.hexString,
            variant: .infoGroupCurrentUserLeaving,
            body: "leaving".localized(),
            timestampMs: dependencies[cache: .storageServer].currentOffsetTimestampMs(),
            using: dependencies
        ).inserted(db)
        
        dependencies[singleton: .jobRunner].upsert(
            db,
            job: Job(
                variant: .groupLeaving,
                threadId: threadId,
                interactionId: interaction.id,
                details: GroupLeavingJob.Details(
                    behaviour: .leave
                )
            ),
            canStartJob: true
        )
    }
}
