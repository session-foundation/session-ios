// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import Sodium
import SessionUtilitiesKit
import SessionSnodeKit

extension MessageSender {
    private typealias PreparedGroupData = (
        groupSessionId: SessionId,
        groupState: [ConfigDump.Variant: SessionUtil.Config],
        thread: SessionThread,
        group: ClosedGroup,
        members: [GroupMember],
        preparedNotificationsSubscription: HTTP.PreparedRequest<PushNotificationAPI.SubscribeResponse>?
    )
    
    public static func createGroup(
        name: String,
        displayPicture: SignalAttachment?,
        members: [(String, Profile?)],
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<SessionThread, Error> {
        return Just(())
            .setFailureType(to: Error.self)
            .flatMap { _ -> AnyPublisher<(url: String, filename: String, encryptionKey: Data)?, Error> in
                guard let displayPicture: SignalAttachment = displayPicture else {
                    return Just(nil)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                // TODO: Upload group image first
                return Just(nil)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
            .flatMap { displayPictureInfo -> AnyPublisher<PreparedGroupData, Error> in
                dependencies[singleton: .storage].writePublisher(using: dependencies) { db -> PreparedGroupData in
                    // Create and cache the libSession entries
                    let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
                    let currentUserProfile: Profile = Profile.fetchOrCreateCurrentUser(db, using: dependencies)
                    let createdInfo: SessionUtil.CreatedGroupInfo = try SessionUtil.createGroup(
                        db,
                        name: name,
                        displayPictureUrl: displayPictureInfo?.url,
                        displayPictureFilename: displayPictureInfo?.filename,
                        displayPictureEncryptionKey: displayPictureInfo?.encryptionKey,
                        members: members,
                        admins: [(userSessionId.hexString, currentUserProfile)],
                        using: dependencies
                    )
                    
                    // Save the relevant objects to the database
                    let thread: SessionThread = try SessionThread
                        .fetchOrCreate(
                            db,
                            id: createdInfo.group.id,
                            variant: .group,
                            shouldBeVisible: true,
                            using: dependencies
                        )
                    try createdInfo.group.insert(db)
                    try createdInfo.members.forEach { try $0.insert(db) }
                    
                    // Prepare the notification subscription
                    let preparedNotificationSubscription = try? PushNotificationAPI
                        .preparedSubscribe(
                            db,
                            sessionId: createdInfo.groupSessionId,
                            using: dependencies
                        )
                    
                    return (
                        createdInfo.groupSessionId,
                        createdInfo.groupState,
                        thread,
                        createdInfo.group,
                        createdInfo.members,
                        preparedNotificationSubscription
                    )
                }
            }
            .flatMap { preparedGroupData -> AnyPublisher<PreparedGroupData, Error> in
                ConfigurationSyncJob
                    .run(sessionIdHexString: preparedGroupData.groupSessionId.hexString, using: dependencies)
                    .flatMap { _ in
                        dependencies[singleton: .storage].writePublisher(using: dependencies) { db in
                            // Save the successfully created group and add to the user config
                            try SessionUtil.saveCreatedGroup(
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
                                    dependencies[singleton: .storage].writeAsync(using: dependencies) { db in
                                        SessionUtil.removeGroupStateIfNeeded(
                                            db,
                                            groupSessionId: preparedGroupData.groupSessionId,
                                            using: dependencies
                                        )
                                        
                                        _ = try? preparedGroupData.thread.delete(db)
                                        _ = try? preparedGroupData.group.delete(db)
                                        try? preparedGroupData.members.forEach { try $0.delete(db) }
                                    }
                            }
                        }
                    )
                    .eraseToAnyPublisher()
            }
            .handleEvents(
                receiveOutput: { _, _, thread, _, members, preparedNotificationSubscription in
                    // Start polling
                    dependencies[singleton: .groupsPoller].startIfNeeded(for: thread.id, using: dependencies)
                    
                    // Subscribe for push notifications (if PNs are enabled)
                    preparedNotificationSubscription?
                        .send(using: dependencies)
                        .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                        .sinkUntilComplete()
                    
                    // Save jobs for sending group member invitations
                    dependencies[singleton: .storage].write(using: dependencies) { db in
                        let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
                        
                        members
                            .filter { $0.profileId != userSessionId.hexString }
                            .forEach { member in
                                dependencies[singleton: .jobRunner].add(
                                    db,
                                    job: Job(
                                        variant: .groupInviteMember,
                                        threadId: thread.id,
                                        details: GroupInviteMemberJob.Details(
                                            memberSubkey: Data(),
                                            memberTag: Data()
                                        )
                                    ),
                                    canStartJob: true,
                                    using: dependencies
                                )
                                
                                // Send admin keys to any admins
                                guard member.role == .admin else { return }
                                
                            }
                    }
                }
            )
            .map { _, _, thread, _, _, _ in thread }
            .eraseToAnyPublisher()
    }
    
    public static func updateGroup(
        groupSessionId: String,
        name: String,
        displayPicture: SignalAttachment?,
        members: [(id: String, profile: Profile?)],
        allowAccessToHistoricMessages: Bool,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Void, Error> {
        guard let sessionId: SessionId = try? SessionId(from: groupSessionId), sessionId.prefix == .group else {
            // FIXME: Fail with `MessageSenderError.invalidClosedGroupUpdate` once support for legacy groups is removed
            return MessageSender.update(
                legacyGroupSessionId: groupSessionId,
                with: members.map { $0.0 }.asSet(),
                name: name,
                using: dependencies
            )
        }
        
        return dependencies[singleton: .storage]
            .writePublisher { db in
                guard
                    let closedGroup: ClosedGroup = try? ClosedGroup.fetchOne(db, id: sessionId.hexString),
                    closedGroup.groupIdentityPrivateKey != nil
                else { throw MessageSenderError.invalidClosedGroupUpdate }
                
                let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
                let changeTimestampMs: Int64 = SnodeAPI.currentOffsetTimestampMs(using: dependencies)
                
                // Update name if needed
                if name != closedGroup.name {
                    // Update the group
                    _ = try ClosedGroup
                        .filter(id: sessionId.hexString)
                        .updateAllAndConfig(db, ClosedGroup.Columns.name.set(to: name), using: dependencies)

                    // Update libSession
                    try SessionUtil.update(
                        db,
                        groupSessionId: sessionId,
                        name: name,
                        using: dependencies
                    )
                    
                    // Add a record of the change to the conversation
                    _ = try Interaction(
                        threadId: groupSessionId,
                        authorId: userSessionId.hexString,
                        variant: .infoGroupUpdated,
                        body: ClosedGroup.MessageInfo
                            .updatedName(name)
                            .infoString,
                        timestampMs: changeTimestampMs
                    ).inserted(db)
                    
                    // Schedule the control message to be sent to the group
                    try MessageSender.send(
                        db,
                        message: GroupUpdateInfoChangeMessage(
                            changeType: .name,
                            updatedName: name,
                            sentTimestamp: UInt64(changeTimestampMs)
                        ),
                        interactionId: nil,
                        threadId: sessionId.hexString,
                        threadVariant: .group,
                        using: dependencies
                    )
                }
                
                // Retrieve member info (from libSession since it's the source of truth)
                let sessionUtilMembersIds: Set<GroupMember> = try SessionUtil.getMembers(
                    groupSessionId: sessionId,
                    using: dependencies
                )
                let originalMemberIds: Set<String> = sessionUtilMembersIds.map { $0.profileId }.asSet()
                let addedMembers: [(id: String, profile: Profile?)] = members
                    .filter { !originalMemberIds.contains($0.0) }
                let removedMemberIds: Set<String> = originalMemberIds
                    .subtracting(members.map { id, _ in id }.asSet())
                
                // Add members if needed (insert member records and schedule invitation sending)
                if !addedMembers.isEmpty {
                    // If we aren't allowing access to historic messages then we need to rekey the group
                    if !allowAccessToHistoricMessages {
                        try SessionUtil.rekey(
                            db,
                            groupSessionId: sessionId,
                            using: dependencies
                        )
                    }
                    
                    // Make the required changes for each added member
                    try addedMembers.forEach { id, profile in
                        // Generate authData for the newly added member
                        let memberAuthData: Data = try SessionUtil.generateAuthData(
                            db,
                            groupSessionId: sessionId,
                            memberId: id,
                            using: dependencies
                        )
                        
                        // Add the member to the database
                        try GroupMember(
                            groupId: sessionId.hexString,
                            profileId: id,
                            role: .standard,
                            roleStatus: .pending,
                            isHidden: false
                        ).upsert(db)
                        
                        // Schedule a job to send an invitation to the newly added member
                        dependencies[singleton: .jobRunner].add(
                            db,
                            job: Job(
                                variant: .groupInviteMember,
                                details: GroupInviteMemberJob.Details(
                                    memberSessionIdHexString: id,
                                    memberAuthData: memberAuthData
                                )
                            ),
                            canStartJob: true,
                            using: dependencies
                        )
                    }
                    
                    // Add a record of the change to the conversation
                    _ = try Interaction(
                        threadId: groupSessionId,
                        authorId: userSessionId.hexString,
                        variant: .infoGroupUpdated,
                        body: ClosedGroup.MessageInfo
                            .addedUsers(
                                names: addedMembers.map { id, profile in
                                    profile?.displayName(for: .group) ??
                                    Profile.truncated(id: id, truncating: .middle)
                                }
                            )
                            .infoString,
                        timestampMs: changeTimestampMs
                    ).inserted(db)
                    
                    // Schedule the control message to be sent to the group
                    try MessageSender.send(
                        db,
                        message: GroupUpdateMemberChangeMessage(
                            changeType: .added,
                            memberPublicKeys: addedMembers.map { Data(hex: $0.id) },
                            sentTimestamp: UInt64(changeTimestampMs)
                        ),
                        interactionId: nil,
                        threadId: sessionId.hexString,
                        threadVariant: .group,
                        using: dependencies
                    )
                }
                
                // Remove members if needed
                if !removedMemberIds.isEmpty {
                    try MessageSender.removeGroupMembers(
                        db,
                        groupSessionId: sessionId,
                        memberIds: removedMemberIds,
                        sendMemberChangedMessage: true,
                        changeTimestampMs: changeTimestampMs,
                        using: dependencies
                    )
                }
            }
            .eraseToAnyPublisher()
    }
    
    public static func removeGroupMembers(
        _ db: Database,
        groupSessionId: SessionId,
        memberIds: Set<String>,
        sendMemberChangedMessage: Bool,
        changeTimestampMs: Int64,
        using dependencies: Dependencies
    ) throws {
        try GroupMember
            .filter(
                GroupMember.Columns.groupId == groupSessionId.hexString &&
                memberIds.contains(GroupMember.Columns.profileId)
            )
            .deleteAll(db)
        
        try SessionUtil.removeMembers(
            db,
            groupSessionId: groupSessionId,
            memberIds: memberIds,
            using: dependencies
        )
        
        
        // Send the member changed message if desired
        if sendMemberChangedMessage {
            let userSessionId: SessionId = getUserSessionId(db, using: dependencies)
            let removedMemberProfiles: [String: Profile] = (try? Profile
                .filter(ids: memberIds)
                .fetchAll(db))
                .defaulting(to: [])
                .reduce(into: [:]) { result, next in result[next.id] = next }
            
            // Add a record of the change to the conversation
            _ = try Interaction(
                threadId: groupSessionId.hexString,
                authorId: userSessionId.hexString,
                variant: .infoGroupUpdated,
                body: ClosedGroup.MessageInfo
                    .removedUsers(
                        names: memberIds.map { id in
                            removedMemberProfiles[id]?.displayName(for: .group) ??
                            Profile.truncated(id: id, truncating: .middle)
                        }
                    )
                    .infoString,
                timestampMs: changeTimestampMs
            ).inserted(db)
            
            // Schedule the control message to be sent to the group
            try MessageSender.send(
                db,
                message: GroupUpdateMemberChangeMessage(
                    changeType: .removed,
                    memberPublicKeys: memberIds.map { Data(hex: $0) },
                    sentTimestamp: UInt64(changeTimestampMs)
                ),
                interactionId: nil,
                threadId: groupSessionId.hexString,
                threadVariant: .group,
                using: dependencies
            )
        }
    }
    
    public static func promoteGroupMembers(
        groupSessionId: String,
        memberIds: Set<String>,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Void, Error> {
        }
    }
}
