// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import Sodium
import SessionUtilitiesKit
import SessionSnodeKit

extension MessageSender {
    private typealias PreparedGroupData = (
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
                    let currentUserPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
                    let currentUserProfile: Profile = Profile.fetchOrCreateCurrentUser(db, using: dependencies)
                    let createdInfo: SessionUtil.CreatedGroupInfo = try SessionUtil.createGroup(
                        db,
                        name: name,
                        displayPictureUrl: displayPictureInfo?.url,
                        displayPictureFilename: displayPictureInfo?.filename,
                        displayPictureEncryptionKey: displayPictureInfo?.encryptionKey,
                        members: members,
                        admins: [(currentUserPublicKey, currentUserProfile)],
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
                            publicKey: createdInfo.group.id,
                            using: dependencies
                        )
                    
                    return (
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
                    .run(publicKey: preparedGroupData.group.id, using: dependencies)
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
                                            groupIdentityPublicKey: preparedGroupData.group.id,
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
                receiveOutput: { _, thread, _, members, preparedNotificationSubscription in
                    // Start polling
                    dependencies[singleton: .closedGroupPoller].startIfNeeded(for: thread.id, using: dependencies)
                    
                    // Subscribe for push notifications (if PNs are enabled)
                    preparedNotificationSubscription?
                        .send(using: dependencies)
                        .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
                        .sinkUntilComplete()
                    
                    // Save jobs for sending group member invitations
                    dependencies[singleton: .storage].write(using: dependencies) { db in
                        let currentUserPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
                        
                        members
                            .filter { $0.profileId != currentUserPublicKey }
                            .forEach { member in
                                dependencies[singleton: .jobRunner].add(
                                    db,
                                    job: Job(
                                        variant: .groupInviteMemberJob,
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
            .map { _, thread, _, _, _ in thread }
            .eraseToAnyPublisher()
    }
    
    public static func updateGroup(
        groupIdentityPublicKey: String,
        name: String,
        displayPicture: SignalAttachment?,
        members: [(String, Profile?)],
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Void, Error> {
        guard SessionId.Prefix(from: groupIdentityPublicKey) == .group else {
            // FIXME: Fail with `MessageSenderError.invalidClosedGroupUpdate` once support for legacy groups is removed
            return MessageSender.update(
                legacyGroupPublicKey: groupIdentityPublicKey,
                with: members.map { $0.0 }.asSet(),
                name: name,
                using: dependencies
            )
        }
        
        return dependencies[singleton: .storage]
            .writePublisher { db in
                guard let closedGroup: ClosedGroup = try? ClosedGroup.fetchOne(db, id: groupIdentityPublicKey) else {
                    throw MessageSenderError.invalidClosedGroupUpdate
                }
                
                // Update name if needed
                if name != closedGroup.name {
                    // Update the group
                    _ = try ClosedGroup
                        .filter(id: groupIdentityPublicKey)
                        .updateAllAndConfig(db, ClosedGroup.Columns.name.set(to: name), using: dependencies)
                }
            }
            .eraseToAnyPublisher()
    }
}
