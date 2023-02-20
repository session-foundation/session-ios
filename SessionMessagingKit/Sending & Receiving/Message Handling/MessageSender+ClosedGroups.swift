// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import Sodium
import Curve25519Kit
import SessionUtilitiesKit
import SessionSnodeKit

extension MessageSender {
    public static var distributingKeyPairs: Atomic<[String: [ClosedGroupKeyPair]]> = Atomic([:])
    
    public static func createClosedGroup(
        _ db: Database,
        name: String,
        members: Set<String>
    ) -> AnyPublisher<SessionThread, Error> {
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        var members: Set<String> = members
        
        // Generate the group's public key
        let groupKeyPair: ECKeyPair = Curve25519.generateKeyPair()
        let groupPublicKey: String = KeyPair(
            publicKey: groupKeyPair.publicKey.bytes,
            secretKey: groupKeyPair.privateKey.bytes
        ).hexEncodedPublicKey // Includes the 'SessionId.Prefix.standard' prefix
        // Generate the key pair that'll be used for encryption and decryption
        let encryptionKeyPair: ECKeyPair = Curve25519.generateKeyPair()
        
        // Create the group
        members.insert(userPublicKey) // Ensure the current user is included in the member list
        let membersAsData = members.map { Data(hex: $0) }
        let admins = [ userPublicKey ]
        let adminsAsData = admins.map { Data(hex: $0) }
        let formationTimestamp: TimeInterval = (TimeInterval(SnodeAPI.currentOffsetTimestampMs()) / 1000)
        let thread: SessionThread
        let memberSendData: [MessageSender.PreparedSendData]
        
        do {
            // Create the relevant objects in the database
            thread = try SessionThread
                .fetchOrCreate(db, id: groupPublicKey, variant: .legacyGroup)
            try ClosedGroup(
                threadId: groupPublicKey,
                name: name,
                formationTimestamp: formationTimestamp
            ).insert(db)
            
            // Store the key pair
            try ClosedGroupKeyPair(
                threadId: groupPublicKey,
                publicKey: encryptionKeyPair.publicKey,
                secretKey: encryptionKeyPair.privateKey,
                receivedTimestamp: (TimeInterval(SnodeAPI.currentOffsetTimestampMs()) / 1000)
            ).insert(db)
            
            // Create the member objects
            try admins.forEach { adminId in
                try GroupMember(
                    groupId: groupPublicKey,
                    profileId: adminId,
                    role: .admin,
                    isHidden: false
                ).insert(db)
            }
            
            try members.forEach { memberId in
                try GroupMember(
                    groupId: groupPublicKey,
                    profileId: memberId,
                    role: .standard,
                    isHidden: false
                ).insert(db)
            }
            
            // Notify the user
            //
            // Note: Intentionally don't want a 'serverHash' for closed group creation
            _ = try Interaction(
                threadId: thread.id,
                authorId: userPublicKey,
                variant: .infoClosedGroupCreated,
                timestampMs: SnodeAPI.currentOffsetTimestampMs()
            ).inserted(db)
            
            memberSendData = try members
                .map { memberId -> MessageSender.PreparedSendData in
                    try MessageSender.preparedSendData(
                        db,
                        message: ClosedGroupControlMessage(
                            kind: .new(
                                publicKey: Data(hex: groupPublicKey),
                                name: name,
                                encryptionKeyPair: Box.KeyPair(
                                    publicKey: encryptionKeyPair.publicKey.bytes,
                                    secretKey: encryptionKeyPair.privateKey.bytes
                                ),
                                members: membersAsData,
                                admins: adminsAsData,
                                expirationTimer: 0
                            ),
                            // Note: We set this here to ensure the value matches
                            // the 'ClosedGroup' object we created
                            sentTimestampMs: UInt64(floor(formationTimestamp * 1000))
                        ),
                        to: .contact(publicKey: memberId),
                        interactionId: nil
                    )
                }
        }
        catch {
            return Fail(error: error)
                .eraseToAnyPublisher()
        }
        
        return Publishers
            .MergeMany(
                // Send a closed group update message to all members individually
                memberSendData
                    .map { MessageSender.sendImmediate(preparedSendData: $0) }
                    .appending(
                        // Notify the PN server
                        PushNotificationAPI.performOperation(
                            .subscribe,
                            for: groupPublicKey,
                            publicKey: userPublicKey
                        )
                    )
            )
            .collect()
            .map { _ in thread }
            .eraseToAnyPublisher()
            .handleEvents(
                receiveCompletion: { result in
                    switch result {
                        case .failure: break
                        case .finished:
                            // Start polling
                            ClosedGroupPoller.shared.startIfNeeded(for: groupPublicKey)
                    }
                }
            )
            .eraseToAnyPublisher()
    }

    /// Generates and distributes a new encryption key pair for the group with the given closed group. This sends an
    /// `ENCRYPTION_KEY_PAIR` message to the group. The message contains a list of key pair wrappers. Each key
    /// pair wrapper consists of the public key for which the wrapper is intended along with the newly generated key pair
    /// encrypted for that public key.
    ///
    /// The returned promise is fulfilled when the message has been sent to the group.
    private static func generateAndSendNewEncryptionKeyPair(
        _ db: Database,
        targetMembers: Set<String>,
        userPublicKey: String,
        allGroupMembers: [GroupMember],
        closedGroup: ClosedGroup,
        thread: SessionThread
    ) -> AnyPublisher<Void, Error> {
        guard allGroupMembers.contains(where: { $0.role == .admin && $0.profileId == userPublicKey }) else {
            return Fail(error: MessageSenderError.invalidClosedGroupUpdate)
                .eraseToAnyPublisher()
        }
        
        let newKeyPair: ClosedGroupKeyPair
        let sendData: MessageSender.PreparedSendData
        
        do {
            // Generate the new encryption key pair
            let legacyNewKeyPair: ECKeyPair = Curve25519.generateKeyPair()
            newKeyPair = ClosedGroupKeyPair(
                threadId: closedGroup.threadId,
                publicKey: legacyNewKeyPair.publicKey,
                secretKey: legacyNewKeyPair.privateKey,
                receivedTimestamp: (TimeInterval(SnodeAPI.currentOffsetTimestampMs()) / 1000)
            )
            
            // Distribute it
            let proto = try SNProtoKeyPair.builder(
                publicKey: newKeyPair.publicKey,
                privateKey: newKeyPair.secretKey
            ).build()
            let plaintext = try proto.serializedData()
            
            distributingKeyPairs.mutate {
                $0[closedGroup.id] = ($0[closedGroup.id] ?? [])
                    .appending(newKeyPair)
            }
            
            sendData = try MessageSender
                .preparedSendData(
                    db,
                    message: ClosedGroupControlMessage(
                        kind: .encryptionKeyPair(
                            publicKey: nil,
                            wrappers: targetMembers.map { memberPublicKey in
                                ClosedGroupControlMessage.KeyPairWrapper(
                                    publicKey: memberPublicKey,
                                    encryptedKeyPair: try MessageSender.encryptWithSessionProtocol(
                                        db,
                                        plaintext: plaintext,
                                        for: memberPublicKey
                                    )
                                )
                            }
                        )
                    ),
                    to: try Message.Destination.from(db, thread: thread),
                    interactionId: nil
                )
        }
        catch {
            return Fail(error: error)
                .eraseToAnyPublisher()
        }
        
        return MessageSender.sendImmediate(preparedSendData: sendData)
            .map { _ in newKeyPair }
            .eraseToAnyPublisher()
            .handleEvents(
                receiveOutput: { newKeyPair in
                    /// Store it **after** having sent out the message to the group
                    Storage.shared.write { db in
                        try newKeyPair.insert(db)
                    }
                    
                    distributingKeyPairs.mutate {
                        if let index = ($0[closedGroup.id] ?? []).firstIndex(of: newKeyPair) {
                            $0[closedGroup.id] = ($0[closedGroup.id] ?? [])
                                .removing(index: index)
                        }
                    }
                }
            )
            .map { _ in () }
            .eraseToAnyPublisher()
    }
    
    public static func update(
        _ db: Database,
        groupPublicKey: String,
        with members: Set<String>,
        name: String
    ) -> AnyPublisher<Void, Error> {
        // Get the group, check preconditions & prepare
        guard let thread: SessionThread = try? SessionThread.fetchOne(db, id: groupPublicKey) else {
            SNLog("Can't update nonexistent closed group.")
            return Fail(error: MessageSenderError.noThread)
                .eraseToAnyPublisher()
        }
        guard let closedGroup: ClosedGroup = try? thread.closedGroup.fetchOne(db) else {
            return Fail(error: MessageSenderError.invalidClosedGroupUpdate)
                .eraseToAnyPublisher()
        }
        
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        
        do {
            // Update name if needed
            if name != closedGroup.name {
                // Update the group
                _ = try ClosedGroup
                    .filter(id: closedGroup.id)
                    .updateAll(db, ClosedGroup.Columns.name.set(to: name))
                
                // Notify the user
                let interaction: Interaction = try Interaction(
                    threadId: thread.id,
                    authorId: userPublicKey,
                    variant: .infoClosedGroupUpdated,
                    body: ClosedGroupControlMessage.Kind
                        .nameChange(name: name)
                        .infoMessage(db, sender: userPublicKey),
                    timestampMs: SnodeAPI.currentOffsetTimestampMs()
                ).inserted(db)
                
                guard let interactionId: Int64 = interaction.id else { throw StorageError.objectNotSaved }
                
                // Send the update to the group
                try MessageSender.send(
                    db,
                    message: ClosedGroupControlMessage(kind: .nameChange(name: name)),
                    interactionId: interactionId,
                    in: thread
                )
            }
        }
        catch {
            return Fail(error: error)
                .eraseToAnyPublisher()
        }
        
        // Retrieve member info
        guard let allGroupMembers: [GroupMember] = try? closedGroup.allMembers.fetchAll(db) else {
            return Fail(error: MessageSenderError.invalidClosedGroupUpdate)
                .eraseToAnyPublisher()
        }
                            
        let standardAndZombieMemberIds: [String] = allGroupMembers
            .filter { $0.role == .standard || $0.role == .zombie }
            .map { $0.profileId }
        let addedMembers: Set<String> = members.subtracting(standardAndZombieMemberIds)
        
        // Add members if needed
        if !addedMembers.isEmpty {
            do {
                try addMembers(
                    db,
                    addedMembers: addedMembers,
                    userPublicKey: userPublicKey,
                    allGroupMembers: allGroupMembers,
                    closedGroup: closedGroup,
                    thread: thread
                )
            }
            catch {
                return Fail(error: MessageSenderError.invalidClosedGroupUpdate)
                    .eraseToAnyPublisher()
            }
        }
        
        // Remove members if needed
        let removedMembers: Set<String> = Set(standardAndZombieMemberIds).subtracting(members)
        
        if !removedMembers.isEmpty {
            do {
                return try removeMembers(
                    db,
                    removedMembers: removedMembers,
                    userPublicKey: userPublicKey,
                    allGroupMembers: allGroupMembers,
                    closedGroup: closedGroup,
                    thread: thread
                )
            }
            catch {
                return Fail(error: MessageSenderError.invalidClosedGroupUpdate)
                    .eraseToAnyPublisher()
            }
        }
        
        return Just(())
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
    

    /// Adds `newMembers` to the group with the given closed group. This sends a `MEMBERS_ADDED` message to the group, and a
    /// `NEW` message to the members that were added (using one-on-one channels).
    private static func addMembers(
        _ db: Database,
        addedMembers: Set<String>,
        userPublicKey: String,
        allGroupMembers: [GroupMember],
        closedGroup: ClosedGroup,
        thread: SessionThread
    ) throws {
        guard let disappearingMessagesConfig: DisappearingMessagesConfiguration = try thread.disappearingMessagesConfiguration.fetchOne(db) else {
            throw StorageError.objectNotFound
        }
        guard let encryptionKeyPair: ClosedGroupKeyPair = try closedGroup.fetchLatestKeyPair(db) else {
            throw StorageError.objectNotFound
        }
        
        let groupMemberIds: [String] = allGroupMembers
            .filter { $0.role == .standard }
            .map { $0.profileId }
        let groupAdminIds: [String] = allGroupMembers
            .filter { $0.role == .admin }
            .map { $0.profileId }
        let members: Set<String> = Set(groupMemberIds).union(addedMembers)
        let membersAsData: [Data] = members.map { Data(hex: $0) }
        let adminsAsData: [Data] = groupAdminIds.map { Data(hex: $0) }
        
        // Notify the user
        let interaction: Interaction = try Interaction(
            threadId: thread.id,
            authorId: userPublicKey,
            variant: .infoClosedGroupUpdated,
            body: ClosedGroupControlMessage.Kind
                .membersAdded(members: addedMembers.map { Data(hex: $0) })
                .infoMessage(db, sender: userPublicKey),
            timestampMs: SnodeAPI.currentOffsetTimestampMs()
        ).inserted(db)
        
        guard let interactionId: Int64 = interaction.id else { throw StorageError.objectNotSaved }
        
        // Send the update to the group
        try MessageSender.send(
            db,
            message: ClosedGroupControlMessage(
                kind: .membersAdded(members: addedMembers.map { Data(hex: $0) })
            ),
            interactionId: interactionId,
            in: thread
        )
        
        try addedMembers.forEach { member in
            // Send updates to the new members individually
            let thread: SessionThread = try SessionThread
                .fetchOrCreate(db, id: member, variant: .contact)
            
            try MessageSender.send(
                db,
                message: ClosedGroupControlMessage(
                    kind: .new(
                        publicKey: Data(hex: closedGroup.id),
                        name: closedGroup.name,
                        encryptionKeyPair: Box.KeyPair(
                            publicKey: encryptionKeyPair.publicKey.bytes,
                            secretKey: encryptionKeyPair.secretKey.bytes
                        ),
                        members: membersAsData,
                        admins: adminsAsData,
                        expirationTimer: (disappearingMessagesConfig.isEnabled ?
                            UInt32(floor(disappearingMessagesConfig.durationSeconds)) :
                            0
                        )
                    )
                ),
                interactionId: nil,
                in: thread
            )
            
            // Add the users to the group
            try GroupMember(
                groupId: closedGroup.id,
                profileId: member,
                role: .standard,
                isHidden: false
            ).insert(db)
        }
    }

    /// Removes `membersToRemove` from the group with the given `groupPublicKey`. Only the admin can remove members, and when they do
    /// they generate and distribute a new encryption key pair for the group. A member cannot leave a group using this method. For that they should use
    /// `leave(:using:)`.
    ///
    /// The returned promise is fulfilled when the `MEMBERS_REMOVED` message has been sent to the group AND the new encryption key pair has been
    /// generated and distributed.
    private static func removeMembers(
        _ db: Database,
        removedMembers: Set<String>,
        userPublicKey: String,
        allGroupMembers: [GroupMember],
        closedGroup: ClosedGroup,
        thread: SessionThread
    ) throws -> AnyPublisher<Void, Error> {
        guard !removedMembers.contains(userPublicKey) else {
            SNLog("Invalid closed group update.")
            throw MessageSenderError.invalidClosedGroupUpdate
        }
        guard allGroupMembers.contains(where: { $0.role == .admin && $0.profileId == userPublicKey }) else {
            SNLog("Only an admin can remove members from a group.")
            throw MessageSenderError.invalidClosedGroupUpdate
        }
        
        let groupMemberIds: [String] = allGroupMembers
            .filter { $0.role == .standard }
            .map { $0.profileId }
        let groupZombieIds: [String] = allGroupMembers
            .filter { $0.role == .zombie }
            .map { $0.profileId }
        let members: Set<String> = Set(groupMemberIds).subtracting(removedMembers)
        
        // Update zombie & member list
        try GroupMember
            .filter(GroupMember.Columns.groupId == thread.id)
            .filter(removedMembers.contains(GroupMember.Columns.profileId))
            .filter([ GroupMember.Role.standard, GroupMember.Role.zombie ].contains(GroupMember.Columns.role))
            .deleteAll(db)
        
        let interactionId: Int64?
        
        // Notify the user if needed (not if only zombie members were removed)
        if !removedMembers.subtracting(groupZombieIds).isEmpty {
            let interaction: Interaction = try Interaction(
                threadId: thread.id,
                authorId: userPublicKey,
                variant: .infoClosedGroupUpdated,
                body: ClosedGroupControlMessage.Kind
                    .membersRemoved(members: removedMembers.map { Data(hex: $0) })
                    .infoMessage(db, sender: userPublicKey),
                timestampMs: SnodeAPI.currentOffsetTimestampMs()
            ).inserted(db)
            
            guard let newInteractionId: Int64 = interaction.id else { throw StorageError.objectNotSaved }
            
            interactionId = newInteractionId
        }
        else {
            interactionId = nil
        }
        
        // Send the update to the group and generate + distribute a new encryption key pair
        return MessageSender
            .sendImmediate(
                preparedSendData: try MessageSender
                    .preparedSendData(
                        db,
                        message: ClosedGroupControlMessage(
                            kind: .membersRemoved(
                                members: removedMembers.map { Data(hex: $0) }
                            )
                        ),
                        to: try Message.Destination.from(db, thread: thread),
                        interactionId: interactionId
                    )
            )
            .flatMap { _ -> AnyPublisher<Void, Error> in
                generateAndSendNewEncryptionKeyPair(
                    db,
                    targetMembers: members,
                    userPublicKey: userPublicKey,
                    allGroupMembers: allGroupMembers,
                    closedGroup: closedGroup,
                    thread: thread
                )
            }
            .eraseToAnyPublisher()
    }
    
    /// Leave the group with the given `groupPublicKey`. If the current user is the admin, the group is disbanded entirely. If the
    /// user is a regular member they'll be marked as a "zombie" member by the other users in the group (upon receiving the leave
    /// message). The admin can then truly remove them later.
    ///
    /// This function also removes all encryption key pairs associated with the closed group and the group's public key, and
    /// unregisters from push notifications.
    ///
    /// The returned promise is fulfilled when the `MEMBER_LEFT` message has been sent to the group.
    public static func leave(
        _ db: Database,
        groupPublicKey: String
    ) -> AnyPublisher<Void, Error> {
        guard let thread: SessionThread = try? SessionThread.fetchOne(db, id: groupPublicKey) else {
            SNLog("Can't leave nonexistent closed group.")
            return Fail(error: MessageSenderError.noThread)
                .eraseToAnyPublisher()
        }
        guard thread.closedGroup.isNotEmpty(db) else {
            return Fail(error: MessageSenderError.invalidClosedGroupUpdate)
                .eraseToAnyPublisher()
        }
        
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        let sendData: MessageSender.PreparedSendData
        
        do {
            // Notify the user
            let interaction: Interaction = try Interaction(
                threadId: thread.id,
                authorId: userPublicKey,
                variant: .infoClosedGroupCurrentUserLeft,
                body: ClosedGroupControlMessage.Kind
                    .memberLeft
                    .infoMessage(db, sender: userPublicKey),
                timestampMs: SnodeAPI.currentOffsetTimestampMs()
            ).inserted(db)
            
            guard let interactionId: Int64 = interaction.id else {
                return Fail(error: StorageError.objectNotSaved)
                    .eraseToAnyPublisher()
            }
            
            // Send the update to the group
            sendData = try MessageSender
                .preparedSendData(
                    db,
                    message: ClosedGroupControlMessage(
                        kind: .memberLeft
                    ),
                    to: try Message.Destination.from(db, thread: thread),
                    interactionId: interactionId
                )
            
            // Update the group (if the admin leaves the group is disbanded)
            let wasAdminUser: Bool = GroupMember
                .filter(GroupMember.Columns.groupId == thread.id)
                .filter(GroupMember.Columns.profileId == userPublicKey)
                .filter(GroupMember.Columns.role == GroupMember.Role.admin)
                .isNotEmpty(db)
            
            if wasAdminUser {
                try GroupMember
                    .filter(GroupMember.Columns.groupId == thread.id)
                    .deleteAll(db)
            }
            else {
                try GroupMember
                    .filter(GroupMember.Columns.groupId == thread.id)
                    .filter(GroupMember.Columns.profileId == userPublicKey)
                    .deleteAll(db)
            }
        }
        catch {
            return Fail(error: error)
                .eraseToAnyPublisher()
        }
        
        return MessageSender
            .sendImmediate(preparedSendData: sendData)
            .handleEvents(
                receiveCompletion: { result in
                    switch result {
                        case .failure: break
                        case .finished: try? ClosedGroup.removeKeysAndUnsubscribe(threadId: groupPublicKey)
                    }
                }
            )
            .eraseToAnyPublisher()
    }
    
    public static func sendLatestEncryptionKeyPair(
        _ db: Database,
        to publicKey: String,
        for groupPublicKey: String
    ) {
        guard let thread: SessionThread = try? SessionThread.fetchOne(db, id: groupPublicKey) else {
            return SNLog("Couldn't send key pair for nonexistent closed group.")
        }
        guard let closedGroup: ClosedGroup = try? thread.closedGroup.fetchOne(db) else {
            return
        }
        guard let allGroupMembers: [GroupMember] = try? closedGroup.allMembers.fetchAll(db) else {
            return
        }
        guard allGroupMembers.contains(where: { $0.role == .standard && $0.profileId == publicKey }) else {
            return SNLog("Refusing to send latest encryption key pair to non-member.")
        }
        
        // Get the latest encryption key pair
        var maybeKeyPair: ClosedGroupKeyPair? = distributingKeyPairs.wrappedValue[groupPublicKey]?.last
        
        if maybeKeyPair == nil {
            maybeKeyPair = try? closedGroup.fetchLatestKeyPair(db)
        }
        
        guard let keyPair: ClosedGroupKeyPair = maybeKeyPair else { return }
        
        // Send it
        do {
            let proto = try SNProtoKeyPair.builder(
                publicKey: keyPair.publicKey,
                privateKey: keyPair.secretKey
            ).build()
            let plaintext = try proto.serializedData()
            let thread: SessionThread = try SessionThread
                .fetchOrCreate(db, id: publicKey, variant: .contact)
            let ciphertext = try MessageSender.encryptWithSessionProtocol(
                db,
                plaintext: plaintext,
                for: publicKey
            )
            
            SNLog("Sending latest encryption key pair to: \(publicKey).")
            try MessageSender.send(
                db,
                message: ClosedGroupControlMessage(
                    kind: .encryptionKeyPair(
                        publicKey: Data(hex: groupPublicKey),
                        wrappers: [
                            ClosedGroupControlMessage.KeyPairWrapper(
                                publicKey: publicKey,
                                encryptedKeyPair: ciphertext
                            )
                        ]
                    )
                ),
                interactionId: nil,
                in: thread
            )
        }
        catch {}
    }
}
