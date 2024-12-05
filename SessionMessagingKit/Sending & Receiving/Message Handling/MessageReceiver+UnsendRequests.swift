// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

extension MessageReceiver {
    public static func handleUnsendRequest(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: UnsendRequest,
        using dependencies: Dependencies
    ) throws {
        let userPublicKey: String = getUserHexEncodedPublicKey(db)
        
        guard message.sender == message.author || userPublicKey == message.sender else { return }
        guard let author: String = message.author, let timestampMs: UInt64 = message.timestamp else { return }
        
        let maybeInteraction: Interaction? = try Interaction
            .filter(Interaction.Columns.timestampMs == Int64(timestampMs))
            .filter(Interaction.Columns.authorId == author)
            .fetchOne(db)
        
        guard
            let interactionId: Int64 = maybeInteraction?.id,
            let interaction: Interaction = maybeInteraction
        else { return }
        
        /// Mark incoming messages as read and remove any of their notifications
        if interaction.variant == .standardIncoming {
            try Interaction.markAsRead(
                db,
                interactionId: interactionId,
                threadId: interaction.threadId,
                threadVariant: threadVariant,
                includingOlder: false,
                trySendReadReceipt: false,
                using: dependencies
            )
            
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: interaction.notificationIdentifiers)
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: interaction.notificationIdentifiers)
        }
        
        /// Retrieve the hashes which should be deleted first (these will be removed by marking the message as deleted)
        let hashes: Set<String> = try Interaction.serverHashesForDeletion(
            db,
            interactionIds: [interactionId]
        )
        
        switch (interaction.variant, (author == message.sender)) {
            case (.standardOutgoing, _), (_, false):
                _ = try interaction.delete(db)
                
            case (_, true):
                _ = try interaction
                    .markingAsDeleted()
                    .saved(db)
                
                _ = try interaction.attachments
                    .deleteAll(db)
                
                if let serverHash: String = interaction.serverHash {
                    try SnodeReceivedMessageInfo.handlePotentialDeletedOrInvalidHash(
                        db,
                        potentiallyInvalidHashes: [serverHash]
                    )
                }
        }
        
        /// Can't delete from the legacy group swarm so only bother for contact conversations
        switch threadVariant {
            case .legacyGroup, .group, .community: break
            case .contact:
                dependencies.storage
                    .readPublisher { db in
                        try SnodeAPI.preparedDeleteMessages(
                            db,
                            swarmPublicKey: userPublicKey,
                            serverHashes: Array(hashes),
                            requireSuccessfulDeletion: false,
                            using: dependencies
                        )
                    }
                    .flatMap { $0.send(using: dependencies) }
                    .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
                    .sinkUntilComplete(
                        receiveCompletion: { result in
                            switch result {
                                case .failure: break
                                case .finished:
                                    /// Since the server deletion was successful we should also remove the `SnodeReceivedMessageInfo`
                                    /// entries for the hashes (otherwise we might try to poll for a hash which no longer exists, resulting in fetching
                                    /// the last 14 days of messages)
                                    dependencies.storage.writeAsync { db in
                                        try SnodeReceivedMessageInfo.handlePotentialDeletedOrInvalidHash(
                                            db,
                                            potentiallyInvalidHashes: Array(hashes)
                                        )
                                    }
                            }
                        }
                    )
        }
    }
}
