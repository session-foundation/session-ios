// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUIKit
import SessionSnodeKit
import SessionUtilitiesKit

public extension MessageViewModel {
    struct DeletionBehaviours {
        public enum Behaviour {
            case markAsDeleted(ids: [Int64], options: Interaction.DeletionOption, threadId: String, threadVariant: SessionThread.Variant)
            case deleteFromDatabase(ids: [Int64], threadId: String)
            case cancelPendingSendJobs([Int64])
            case preparedRequest(Network.PreparedRequest<Void>)
        }
        
        public struct NamedAction {
            public enum State {
                case enabledAndDefaultSelected
                case enabled
                case disabled
            }
            
            public let title: String
            public let state: State
            public let accessibility: Accessibility
            let behaviours: [Behaviour]
            
            init(
                title: String,
                state: State,
                accessibility: Accessibility,
                behaviours: [Behaviour] = []
            ) {
                self.title = title
                self.state = state
                self.accessibility = accessibility
                self.behaviours = behaviours
            }
        }
        
        public let title: String
        public let warning: String?
        public let body: String
        public let actions: [NamedAction]
        
        public func requiresNetworkRequestForAction(at index: Int) -> Bool {
            guard index >= 0, index < actions.count else {
                return false
            }
            
            return actions[index].behaviours.contains { behaviour in
                switch behaviour {
                    case .preparedRequest: return true
                    case .cancelPendingSendJobs, .deleteFromDatabase, .markAsDeleted: return false
                }
            }
        }
        
        /// Collect the actions and construct a publisher which triggers each action before returning the result
        public func publisherForAction(at index: Int, using dependencies: Dependencies) -> AnyPublisher<Void, Error> {
            guard index >= 0, index < actions.count else {
                return Fail(error: StorageError.objectNotFound).eraseToAnyPublisher()
            }
            
            var result: AnyPublisher<Void, Error> = Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
            
            actions[index].behaviours.forEach { behaviour in
                switch behaviour {
                    case .cancelPendingSendJobs(let ids):
                        result = result.flatMapStorageWritePublisher(using: dependencies) { db, _ in
                            /// Cancel any `messageSend` jobs related to the message we are deleting
                            let jobs: [Job] = (try? Job
                                .filter(Job.Columns.variant == Job.Variant.messageSend)
                                .filter(ids.contains(Job.Columns.interactionId))
                                .fetchAll(db))
                                .defaulting(to: [])
                            
                            jobs.forEach { dependencies[singleton: .jobRunner].removePendingJob($0) }
                            
                            _ = try? Job.deleteAll(db, ids: jobs.compactMap { $0.id })
                        }
                    
                    case .markAsDeleted(let ids, let options, let threadId, let threadVariant):
                        result = result.flatMapStorageWritePublisher(using: dependencies) { db, _ in
                            try Interaction.markAsDeleted(
                                db,
                                threadId: threadId,
                                threadVariant: threadVariant,
                                interactionIds: Set(ids),
                                options: options,
                                using: dependencies
                            )
                        }
                        
                    case .deleteFromDatabase(let ids, let threadId):
                        result = result.flatMapStorageWritePublisher(using: dependencies) { db, _ in
                            _ = try Interaction
                                .filter(ids: ids)
                                .deleteAll(db)
                            ids.forEach { id in
                                db.addMessageEvent(id: id, threadId: threadId, type: .deleted)
                            }
                        }
                        
                    case .preparedRequest(let preparedRequest):
                        result = result
                            .flatMap { _ in preparedRequest.send(using: dependencies) }
                            .map { _, _ in () }
                            .eraseToAnyPublisher()
                }
            }
            
            return result
        }
    }
}

public extension MessageViewModel.DeletionBehaviours {
    static func deletionActions(
        for cellViewModels: [MessageViewModel],
        with threadData: SessionThreadViewModel,
        using dependencies: Dependencies
    ) -> MessageViewModel.DeletionBehaviours? {
        enum SelectedMessageState {
            case outgoingOnly
            case containsIncoming
            case containsDeletedOrControlMessages
        }
        
        /// If it's a legacy group and they have been deprecated then the user shouldn't be able to delete messages
        guard threadData.threadVariant != .legacyGroup else { return nil }
        
        /// First determine the state of the selected messages
        let state: SelectedMessageState = {
            guard
                !cellViewModels.contains(where: { $0.variant.isDeletedMessage }) &&
                !cellViewModels.contains(where: { $0.variant.isInfoMessage })
            else { return .containsDeletedOrControlMessages }
            
            return (cellViewModels.contains(where: { $0.variant == .standardIncoming }) ?
                .containsIncoming :
                .outgoingOnly
            )
        }()
        
        /// The remaining deletion options are more complicated to determine
        // FIXME: [Database Relocation] Remove this database usage
        var deletionBehaviours: MessageViewModel.DeletionBehaviours?
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        
        dependencies[singleton: .storage].readAsync(
            retrieve: { [dependencies] db -> MessageViewModel.DeletionBehaviours? in
                let isAdmin: Bool = {
                    switch threadData.threadVariant {
                        case .contact: return false
                        case .group, .legacyGroup: return (threadData.currentUserIsClosedGroupAdmin == true)
                        case .community:
                            guard
                                let server: String = threadData.openGroupServer,
                                let roomToken: String = threadData.openGroupRoomToken
                            else { return false }
                            
                            return dependencies[singleton: .openGroupManager].isUserModeratorOrAdmin(
                                db,
                                publicKey: threadData.currentUserSessionId,
                                for: roomToken,
                                on: server,
                                currentUserSessionIds: (threadData.currentUserSessionIds ?? [])
                            )
                    }
                }()
                
                switch (state, isAdmin) {
                    /// User selects messages including a control message or “deleted” message
                    case (.containsDeletedOrControlMessages, _):
                        return MessageViewModel.DeletionBehaviours(
                            title: "deleteMessage"
                                .putNumber(cellViewModels.count)
                                .localized(),
                            warning: (threadData.threadIsNoteToSelf ?
                                "deleteMessageNoteToSelfWarning"
                                    .putNumber(cellViewModels.count)
                                    .localized() :
                                "deleteMessageWarning"
                                    .putNumber(cellViewModels.count)
                                    .localized()
                            ),
                            body: "deleteMessageConfirm"
                                .putNumber(cellViewModels.count)
                                .localized(),
                            actions: [
                                NamedAction(
                                    title: "deleteMessageDeviceOnly".localized(),
                                    state: .enabledAndDefaultSelected,
                                    accessibility: Accessibility(identifier: "Delete for me"),
                                    behaviours: [
                                        .cancelPendingSendJobs(cellViewModels.map { $0.id }),
                                        
                                        /// Control messages and deleted messages should be immediately deleted from the database
                                        .deleteFromDatabase(
                                            ids: cellViewModels
                                                .filter { viewModel in
                                                    viewModel.variant.isInfoMessage ||
                                                    viewModel.variant.isDeletedMessage
                                                }
                                                .map { $0.id },
                                            threadId: threadData.threadId
                                        ),
                                        
                                        /// Other message types should only be marked as deleted
                                        .markAsDeleted(
                                            ids: cellViewModels
                                                .filter { viewModel in
                                                    !viewModel.variant.isInfoMessage &&
                                                    !viewModel.variant.isDeletedMessage
                                                }
                                                .map { $0.id },
                                            options: .local,
                                            threadId: threadData.threadId,
                                            threadVariant: threadData.threadVariant
                                        )
                                    ]
                                ),
                                NamedAction(
                                    title: (threadData.threadIsNoteToSelf ?
                                        "deleteMessageDevicesAll".localized() :
                                        "deleteMessageEveryone".localized()
                                    ),
                                    state: .disabled,
                                    accessibility: Accessibility(identifier: "Delete for everyone")
                                )
                            ]
                        )
                    
                    /// User selects messages including only their own messages
                    case (.outgoingOnly, _):
                        return MessageViewModel.DeletionBehaviours(
                            title: "deleteMessage"
                                .putNumber(cellViewModels.count)
                                .localized(),
                            warning: nil,
                            body: "deleteMessageConfirm"
                                .putNumber(cellViewModels.count)
                                .localized(),
                            actions: [
                                NamedAction(
                                    title: "deleteMessageDeviceOnly".localized(),
                                    state: .enabledAndDefaultSelected,
                                    accessibility: Accessibility(identifier: "Delete for me"),
                                    behaviours: [
                                        .cancelPendingSendJobs(cellViewModels.map { $0.id }),
                                        .markAsDeleted(
                                            ids: cellViewModels.map { $0.id },
                                            options: .local,
                                            threadId: threadData.threadId,
                                            threadVariant: threadData.threadVariant
                                        )
                                    ]
                                ),
                                NamedAction(
                                    title: (threadData.threadIsNoteToSelf ?
                                        "deleteMessageDevicesAll".localized() :
                                        "deleteMessageEveryone".localized()
                                    ),
                                    state: .enabled,
                                    accessibility: Accessibility(identifier: "Delete for everyone"),
                                    behaviours: try deleteForEveryoneBehaviours(
                                        db,
                                        isAdmin: isAdmin,
                                        threadData: threadData,
                                        cellViewModels: cellViewModels,
                                        using: dependencies
                                    )
                                )
                            ]
                        )
                        
                    /// User selects messages including ones from other users
                    case (.containsIncoming, false):
                        return MessageViewModel.DeletionBehaviours(
                            title: "deleteMessage"
                                .putNumber(cellViewModels.count)
                                .localized(),
                            warning: "deleteMessageWarning"
                                .putNumber(cellViewModels.count)
                                .localized(),
                            body: "deleteMessageDescriptionDevice"
                                .putNumber(cellViewModels.count)
                                .localized(),
                            actions: [
                                NamedAction(
                                    title: "deleteMessageDeviceOnly".localized(),
                                    state: .enabledAndDefaultSelected,
                                    accessibility: Accessibility(identifier: "Delete for me"),
                                    behaviours: [
                                        .cancelPendingSendJobs(cellViewModels.map { $0.id }),
                                        .markAsDeleted(
                                            ids: cellViewModels.map { $0.id },
                                            options: .local,
                                            threadId: threadData.threadId,
                                            threadVariant: threadData.threadVariant
                                        )
                                    ]
                                ),
                                NamedAction(
                                    title: "deleteMessageEveryone".localized(),
                                    state: .disabled,
                                    accessibility: Accessibility(identifier: "Delete for everyone")
                                )
                            ]
                        )
                        
                    /// Admin can multi-select their own messages and messages from other users
                    case (.containsIncoming, true):
                        return MessageViewModel.DeletionBehaviours(
                            title: "deleteMessage"
                                .putNumber(cellViewModels.count)
                                .localized(),
                            warning: nil,
                            body: "deleteMessageConfirm"
                                .putNumber(cellViewModels.count)
                                .localized(),
                            actions: [
                                NamedAction(
                                    title: "deleteMessageDeviceOnly".localized(),
                                    state: .enabled,
                                    accessibility: Accessibility(identifier: "Delete for me"),
                                    behaviours: [
                                        .cancelPendingSendJobs(cellViewModels.map { $0.id }),
                                        .markAsDeleted(
                                            ids: cellViewModels.map { $0.id },
                                            options: .local,
                                            threadId: threadData.threadId,
                                            threadVariant: threadData.threadVariant
                                        )
                                    ]
                                ),
                                NamedAction(
                                    title: "deleteMessageEveryone".localized(),
                                    state: .enabledAndDefaultSelected,
                                    accessibility: Accessibility(identifier: "Delete for everyone"),
                                    behaviours: try deleteForEveryoneBehaviours(
                                        db,
                                        isAdmin: isAdmin,
                                        threadData: threadData,
                                        cellViewModels: cellViewModels,
                                        using: dependencies
                                    )
                                )
                            ]
                        )
                }
            },
            completion: { result in
                deletionBehaviours = try? result.successOrThrow()
                semaphore.signal()
            }
        )
        semaphore.wait()
        
        return deletionBehaviours
    }
    
    private static func deleteForEveryoneBehaviours(
        _ db: ObservingDatabase,
        isAdmin: Bool,
        threadData: SessionThreadViewModel,
        cellViewModels: [MessageViewModel],
        using dependencies: Dependencies
    ) throws -> [Behaviour] {
        /// The non-local deletion behaviours differ depending on the type of conversation
        switch (threadData.threadVariant, isAdmin) {
            /// **Note to Self or Contact Conversation**
            /// Delete from all participant devices via an `UnsendRequest` (these will trigger their own sync messages)
            /// Delete from the current users swarm (where possible)
            /// Mark as deleted
            case (.contact, _):
                /// Only include messages sent by the current user (can't delete incoming messages in contact conversations)
                let targetViewModels: [MessageViewModel] = cellViewModels
                    .filter { threadData.currentUserSessionId.contains($0.authorId) }
                let serverHashes: Set<String> = targetViewModels.compactMap { $0.serverHash }.asSet()
                    .inserting(contentsOf: Set(targetViewModels.flatMap { message in
                        (message.reactionInfo ?? []).compactMap { $0.reaction.serverHash }
                    }))
                let unsendRequests: [Network.PreparedRequest<Void>] = try targetViewModels.map { model in
                    try MessageSender.preparedSend(
                        message: UnsendRequest(
                            timestamp: UInt64(model.timestampMs),
                            author: threadData.currentUserSessionId
                        )
                        .with(
                            expiresInSeconds: model.expiresInSeconds,
                            expiresStartedAtMs: model.expiresStartedAtMs
                        ),
                        to: .contact(publicKey: model.threadId),
                        namespace: .default,
                        interactionId: nil,
                        attachments: nil,
                        authMethod: try Authentication.with(
                            db,
                            threadId: threadData.threadId,
                            threadVariant: threadData.threadVariant,
                            using: dependencies
                        ),
                        onEvent: MessageSender.standardEventHandling(using: dependencies),
                        using: dependencies
                    )
                    .map { _, _ in () }
                }
                
                /// Batch requests have a limited number of subrequests so make sure to chunk
                /// the unsend requests accordingly
                return [.cancelPendingSendJobs(targetViewModels.map { $0.id })]
                    .appending(
                        contentsOf: try unsendRequests
                            .chunked(by: Network.BatchRequest.childRequestLimit)
                            .map { unsendRequestChunk in
                                .preparedRequest(
                                    try SnodeAPI.preparedBatch(
                                        requests: unsendRequestChunk,
                                        requireAllBatchResponses: false,
                                        swarmPublicKey: threadData.threadId,
                                        using: dependencies
                                    ).map { _, _ in () }
                                )
                            }
                    )
                    .appending(serverHashes.isEmpty ? nil :
                        .preparedRequest(
                            try SnodeAPI.preparedDeleteMessages(
                                serverHashes: Array(serverHashes),
                                requireSuccessfulDeletion: false,
                                authMethod: try Authentication.with(
                                    db,
                                    swarmPublicKey: threadData.currentUserSessionId,
                                    using: dependencies
                                ),
                                using: dependencies
                            )
                            .map { _, _ in () }
                        )
                    )
                    .appending(threadData.threadIsNoteToSelf ?
                        /// If it's the `Note to Self`conversation then we want to just delete the interaction
                        .deleteFromDatabase(
                            ids: cellViewModels.map { $0.id },
                            threadId: threadData.threadId
                        ) :
                        .markAsDeleted(
                            ids: targetViewModels.map { $0.id },
                            options: [.local, .network],
                            threadId: threadData.threadId,
                            threadVariant: threadData.threadVariant
                        )
                    )
                
            /// **Legacy Group Conversation**
            /// Delete from all participant devices via an `UnsendRequest`
            /// Mark as deleted
            ///
            /// **Note:** We **cannot** delete from the legacy group swarm
            case (.legacyGroup, _):
                /// Only try to delete messages send by other users if the current user is an admin
                let targetViewModels: [MessageViewModel] = cellViewModels
                    .filter { isAdmin || (threadData.currentUserSessionIds ?? []).contains($0.authorId) }
                let unsendRequests: [Network.PreparedRequest<Void>] = try targetViewModels.map { model in
                    try MessageSender.preparedSend(
                        message: UnsendRequest(
                            timestamp: UInt64(model.timestampMs),
                            author: (model.variant == .standardOutgoing ?
                                threadData.currentUserSessionId :
                                model.authorId
                            )
                        )
                        .with(
                            expiresInSeconds: model.expiresInSeconds,
                            expiresStartedAtMs: model.expiresStartedAtMs
                        ),
                        to: .closedGroup(groupPublicKey: model.threadId),
                        namespace: .legacyClosedGroup,
                        interactionId: nil,
                        attachments: nil,
                        authMethod: try Authentication.with(
                            db,
                            threadId: threadData.threadId,
                            threadVariant: threadData.threadVariant,
                            using: dependencies
                        ),
                        onEvent: MessageSender.standardEventHandling(using: dependencies),
                        using: dependencies
                    )
                    .map { _, _ in () }
                }
                
                /// Batch requests have a limited number of subrequests so make sure to chunk
                /// the unsend requests accordingly
                return [.cancelPendingSendJobs(targetViewModels.map { $0.id })]
                    .appending(
                        contentsOf: try unsendRequests
                            .chunked(by: Network.BatchRequest.childRequestLimit)
                            .map { unsendRequestChunk in
                                .preparedRequest(
                                    try SnodeAPI.preparedBatch(
                                        requests: unsendRequestChunk,
                                        requireAllBatchResponses: false,
                                        swarmPublicKey: threadData.threadId,
                                        using: dependencies
                                    ).map { _, _ in () }
                                )
                            }
                    )
                    .appending(
                        .markAsDeleted(
                            ids: targetViewModels.map { $0.id },
                            options: [.local, .network],
                            threadId: threadData.threadId,
                            threadVariant: threadData.threadVariant
                        )
                    )
            
            /// **Group Conversation for Non Admin**
            /// Delete from all participant devices via an `GroupUpdateDeleteMemberContentMessage`
            /// Mark as deleted
            ///
            /// **Note:** Non-admins **cannot** delete from the group swarm
            case (.group, false):
                /// Only include messages sent by the current user (non-admins can't delete incoming messages in group conversations)
                let targetViewModels: [MessageViewModel] = cellViewModels
                    .filter { (threadData.currentUserSessionIds ?? []).contains($0.authorId) }
                let serverHashes: Set<String> = targetViewModels.compactMap { $0.serverHash }.asSet()
                    .inserting(contentsOf: Set(targetViewModels.flatMap { message in
                        (message.reactionInfo ?? []).compactMap { $0.reaction.serverHash }
                    }))
                
                return [.cancelPendingSendJobs(targetViewModels.map { $0.id })]
                    /// **Note:** No signature for member delete content
                    .appending(serverHashes.isEmpty ? nil :
                        .preparedRequest(try MessageSender
                            .preparedSend(
                                message: GroupUpdateDeleteMemberContentMessage(
                                    memberSessionIds: [],
                                    messageHashes: Array(serverHashes),
                                    sentTimestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs(),
                                    authMethod: nil,
                                    using: dependencies
                                ),
                                to: .closedGroup(groupPublicKey: threadData.threadId),
                                namespace: .groupMessages,
                                interactionId: nil,
                                attachments: nil,
                                authMethod: try Authentication.with(
                                    db,
                                    threadId: threadData.threadId,
                                    threadVariant: threadData.threadVariant,
                                    using: dependencies
                                ),
                                onEvent: MessageSender.standardEventHandling(using: dependencies),
                                using: dependencies
                            )
                            .map { _, _ in () }
                        )
                    )
                    .appending(
                        .markAsDeleted(
                            ids: targetViewModels.map { $0.id },
                            options: [.local, .network],
                            threadId: threadData.threadId,
                            threadVariant: threadData.threadVariant
                        )
                    )
                
            /// **Group Conversation for Admin**
            /// Delete from all participant devices via an `GroupUpdateDeleteMemberContentMessage`
            /// Delete from the group swarm
            /// Mark as deleted
            case (.group, true):
                guard
                    let ed25519SecretKey: [UInt8] = dependencies.mutate(cache: .libSession, { cache in
                        cache.secretKey(groupSessionId: SessionId(.group, hex: threadData.threadId))
                    })
                else {
                    Log.error("[ConversationViewModel] Failed to retrieve groupIdentityPrivateKey when trying to delete messages from group.")
                    throw StorageError.objectNotFound
                }
                
                /// Only try to delete messages with server hashes (can't delete them otherwise)
                let serverHashes: Set<String> = cellViewModels.compactMap { $0.serverHash }.asSet()
                    .inserting(contentsOf: Set(cellViewModels.flatMap { message in
                        (message.reactionInfo ?? []).compactMap { $0.reaction.serverHash }
                    }))
                
                return [.cancelPendingSendJobs(cellViewModels.map { $0.id })]
                    .appending(serverHashes.isEmpty ? nil :
                        .preparedRequest(try MessageSender
                            .preparedSend(
                                message: GroupUpdateDeleteMemberContentMessage(
                                    memberSessionIds: [],
                                    messageHashes: Array(serverHashes),
                                    sentTimestampMs: dependencies[cache: .snodeAPI].currentOffsetTimestampMs(),
                                    authMethod: Authentication.groupAdmin(
                                        groupSessionId: SessionId(.group, hex: threadData.threadId),
                                        ed25519SecretKey: ed25519SecretKey
                                    ),
                                    using: dependencies
                                ),
                                to: .closedGroup(groupPublicKey: threadData.threadId),
                                namespace: .groupMessages,
                                interactionId: nil,
                                attachments: nil,
                                authMethod: try Authentication.with(
                                    db,
                                    threadId: threadData.threadId,
                                    threadVariant: threadData.threadVariant,
                                    using: dependencies
                                ),
                                onEvent: MessageSender.standardEventHandling(using: dependencies),
                                using: dependencies
                            )
                            .map { _, _ in () }
                        )
                    )
                    .appending(serverHashes.isEmpty ? nil :
                        .preparedRequest(try SnodeAPI
                            .preparedDeleteMessages(
                                serverHashes: Array(serverHashes),
                                requireSuccessfulDeletion: false,
                                authMethod: Authentication.groupAdmin(
                                    groupSessionId: SessionId(.group, hex: threadData.threadId),
                                    ed25519SecretKey: Array(ed25519SecretKey)
                                ),
                                using: dependencies
                            )
                            .map { _, _ in () })
                    )
                    .appending(
                        .markAsDeleted(
                            ids: cellViewModels.map { $0.id },
                            options: [.local, .network],
                            threadId: threadData.threadId,
                            threadVariant: threadData.threadVariant
                        )
                    )
            
            /// **Community Conversation**
            /// Delete from the SOGS
            /// Delete from the current device
            ///
            /// **Note:** To simplify the logic (since the sender is a blinded id) we don't bother doing admin/sender checks here
            /// and just rely on the UI state or the SOGS server (if the UI allows an invalid case) to prevent invalid behaviours
            case (.community, _):
                guard let roomToken: String = threadData.openGroupRoomToken else {
                    Log.error("[ConversationViewModel] Failed to retrieve community info when trying to delete messages.")
                    throw StorageError.objectNotFound
                }
                
                let authMethod: AuthenticationMethod = try Authentication.with(
                    db,
                    threadId: threadData.threadId,
                    threadVariant: threadData.threadVariant,
                    using: dependencies
                )
                let deleteRequests: [Network.PreparedRequest] = try cellViewModels
                    .compactMap { $0.openGroupServerMessageId }
                    .map { messageId in
                        try OpenGroupAPI.preparedMessageDelete(
                            id: messageId,
                            roomToken: roomToken,
                            authMethod: authMethod,
                            using: dependencies
                        )
                    }
                
                /// Batch requests have a limited number of subrequests so make sure to chunk
                /// the unsend requests accordingly
                return [.cancelPendingSendJobs(cellViewModels.map { $0.id })]
                    .appending(
                        contentsOf: try deleteRequests
                            .chunked(by: Network.BatchRequest.childRequestLimit)
                            .map { deleteRequestsChunk in
                                .preparedRequest(
                                    try OpenGroupAPI.preparedBatch(
                                        requests: deleteRequestsChunk,
                                        authMethod: authMethod,
                                        using: dependencies
                                    )
                                    .map { _, _ in () }
                                )
                            }
                    )
                    .appending(
                        .deleteFromDatabase(
                            ids: cellViewModels.map { $0.id },
                            threadId: threadData.threadId
                        )
                    )
        }
    }
}
