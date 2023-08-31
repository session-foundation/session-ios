// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import Sodium
import SessionUtilitiesKit
import SessionSnodeKit

extension MessageSender {
    private typealias PreparedGroupData = (
        thread: SessionThread,
        group: ClosedGroup,
        members: [GroupMember],
        preparedNotificationsSubscription: HTTP.PreparedRequest<PushNotificationAPI.SubscribeResponse>?,
        currentUserPublicKey: String
    )
    public static func createGroup(
        name: String,
        displayPicture: SignalAttachment?,
        members: [(String, Profile?)],
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<SessionThread, Error> {
        Just(())
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
            .map { displayPictureInfo -> PreparedGroupData? in
                dependencies.storage.write { db -> PreparedGroupData in
                    // Create and cache the libSession entries
                    let currentUserPublicKey: String = getUserHexEncodedPublicKey(db, using: dependencies)
                    let currentUserProfile: Profile = Profile.fetchOrCreateCurrentUser(db, using: dependencies)
                    let groupData: (identityKeyPair: KeyPair, group: ClosedGroup, members: [GroupMember]) = try SessionUtil.createGroup(
                        db,
                        name: name,
                        displayPictureUrl: displayPictureInfo?.url,
                        displayPictureFilename: displayPictureInfo?.filename,
                        displayPictureEncryptionKey: displayPictureInfo?.encryptionKey,
                        members: members,
                        admins: [(currentUserPublicKey, currentUserProfile)],
                        using: dependencies
                    )
                    let preparedNotificationSubscription = try? PushNotificationAPI
                        .preparedSubscribe(
                            publicKey: groupData.group.id,
                            subkey: nil,
                            ed25519KeyPair: groupData.identityKeyPair,
                            using: dependencies
                        )
                    
                    // Save the relevant objects to the database
                    let thread: SessionThread = try SessionThread
                        .fetchOrCreate(
                            db,
                            id: groupData.group.id,
                            variant: .group,
                            shouldBeVisible: true,
                            using: dependencies
                        )
                    try groupData.group.insert(db)
                    try groupData.members.forEach { try $0.insert(db) }
                    
                    return (
                        thread,
                        groupData.group,
                        groupData.members,
                        preparedNotificationSubscription,
                        currentUserPublicKey
                    )
                }
            }
            .tryFlatMap { maybePreparedData -> AnyPublisher<PreparedGroupData, Error> in
                guard let preparedData: PreparedGroupData = maybePreparedData else {
                    throw StorageError.failedToSave
                }
                
                return ConfigurationSyncJob
                    .run(publicKey: preparedData.group.id, using: dependencies)
                    .map { _ in preparedData }
                    .eraseToAnyPublisher()
            }
            .handleEvents(
                receiveOutput: { _, group, members, preparedNotificationSubscription, currentUserPublicKey in
                    // Start polling
                    ClosedGroupPoller.shared.startIfNeeded(for: group.id, using: dependencies)
                    
                    // Subscribe for push notifications (if PNs are enabled)
                    preparedNotificationSubscription?
                        .send(using: dependencies)
                        .subscribe(on: DispatchQueue.global(qos: .userInitiated))
                        .sinkUntilComplete()
                    
                    // Save jobs for sending group member invitations
                    dependencies.storage.write { db in
                        members
                            .filter { $0.profileId != currentUserPublicKey }
                            .forEach { member in
                                dependencies.jobRunner.add(
                                    db,
                                    job: Job(
                                        variant: .groupInviteMemberJob,
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
            .map { thread, _, _, _, _ in thread }
            .eraseToAnyPublisher()
    }
}
