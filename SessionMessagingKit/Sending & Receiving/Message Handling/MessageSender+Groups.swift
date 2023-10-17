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
        members: [(id: String, profile: Profile?, isAdmin: Bool)],
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Void, Error> {
        guard (try? SessionId.Prefix(from: groupSessionId)) == .group else {
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
                guard let closedGroup: ClosedGroup = try? ClosedGroup.fetchOne(db, id: groupSessionId) else {
                    throw MessageSenderError.invalidClosedGroupUpdate
                }
                
                // Update name if needed
                if name != closedGroup.name {
                    // Update the group
                    _ = try ClosedGroup
                        .filter(id: groupSessionId)
                        .updateAllAndConfig(db, ClosedGroup.Columns.name.set(to: name), using: dependencies)
                }
                
                // Retrieve member info
                guard let allGroupMembers: [GroupMember] = try? closedGroup.allMembers.fetchAll(db) else {
                    throw MessageSenderError.invalidClosedGroupUpdate
                }

                let originalMemberIds: Set<String> = allGroupMembers.map { $0.profileId }.asSet()
                let addedMembers: [(id: String, profile: Profile?, isAdmin: Bool)] = members
                    .filter { !originalMemberIds.contains($0.0) }
                let removedMemberIds: Set<String> = originalMemberIds
                    .subtracting(members.map { id, _, _ in id }.asSet())
                
                // Update libSession (libSession will figure out if it's member list changed)
                try? SessionUtil.update(
                    db,
                    groupSessionId: groupSessionId,
                    members: members,
                    using: dependencies
                )
            }
            .eraseToAnyPublisher()
    }
}
