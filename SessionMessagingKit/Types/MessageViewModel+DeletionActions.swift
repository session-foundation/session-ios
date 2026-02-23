// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit

public extension MessageViewModel {
    struct DeletionBehaviours {
        public enum Behaviour {
            case markAsDeleted(ids: [Int64], options: Interaction.DeletionOption, threadId: String, threadVariant: SessionThread.Variant)
            case deleteFromDatabase([Int64])
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
        
        public func performActions(for index: Int, using dependencies: Dependencies) async throws {
            guard index >= 0, index < actions.count else {
                throw StorageError.objectNotFound
            }
            
            // FIXME: Could probably split the array into groups and perform database actions which are next to each other in a single transaction instead of multiple
            for behaviour in actions[index].behaviours {
                switch behaviour {
                    case .cancelPendingSendJobs(let ids):
                        let jobIds: Set<Int64> = try await dependencies[singleton: .storage].writeAsync { db in
                            /// Cancel any `messageSend` jobs related to the message we are deleting
                            let jobIds: Set<Int64> = ((try? Job
                                .select(Job.Columns.id)
                                .filter(Job.Columns.variant == Job.Variant.messageSend)
                                .filter(ids.contains(Job.Columns.interactionId))
                                .asRequest(of: Int64.self)
                                .fetchSet(db)) ?? [])
                            
                            _ = try? Job.deleteAll(db, ids: jobIds)
                            
                            return jobIds
                        }
                        
                        for jobId in jobIds {
                            await dependencies[singleton: .jobRunner].removePendingJob(jobId)
                        }
                        
                    case .markAsDeleted(let ids, let options, let threadId, let threadVariant):
                        try await dependencies[singleton: .storage].writeAsync { db in
                            try Interaction.markAsDeleted(
                                db,
                                threadId: threadId,
                                threadVariant: threadVariant,
                                interactionIds: Set(ids),
                                options: options,
                                using: dependencies
                            )
                        }
                        
                    case .deleteFromDatabase(let ids):
                        try await dependencies[singleton: .storage].writeAsync { db in
                            try Interaction.deleteWhere(db, .filter(ids.contains(Interaction.Columns.id)))
                        }
                        
                    case .preparedRequest(let request):
                        (_, _) = try await request.send(using: dependencies)
                }
            }
        }
    }
}

public extension MessageViewModel.DeletionBehaviours {
    static func deletionActions(
        for cellViewModels: [MessageViewModel],
        threadInfo: ConversationInfoViewModel,
        authMethod: AuthenticationMethod,
        isUserModeratorOrAdmin: Bool,
        using dependencies: Dependencies
    ) throws -> MessageViewModel.DeletionBehaviours? {
        enum SelectedMessageState {
            case outgoingOnly
            case containsIncoming
            case containsLocalOnlyMessages /// Control, pending or deleted messages
        }
        
        /// If it's a legacy group and they have been deprecated then the user shouldn't be able to delete messages
        guard threadInfo.variant != .legacyGroup else { return nil }
        
        /// First determine the state of the selected messages
        let state: SelectedMessageState = {
            guard
                !cellViewModels.contains(where: { $0.variant.isDeletedMessage }) &&
                !cellViewModels.contains(where: { $0.variant.isInfoMessage }) &&
                !cellViewModels.contains(where: { $0.state == .sending || $0.state == .failed })
            else { return .containsLocalOnlyMessages }
            
            return (cellViewModels.contains(where: { $0.variant == .standardIncoming }) ?
                .containsIncoming :
                .outgoingOnly
            )
        }()
        
        /// The remaining deletion options are more complicated to determine
        let isAdmin: Bool = {
            switch threadInfo.variant {
                case .contact: return false
                case .group, .legacyGroup: return (threadInfo.groupInfo?.currentUserRole == .admin)
                case .community: return isUserModeratorOrAdmin
            }
        }()
        
        switch (state, isAdmin) {
            /// User selects messages including a control, pending or “deleted” message
            case (.containsLocalOnlyMessages, _):
                return MessageViewModel.DeletionBehaviours(
                    title: "deleteMessage"
                        .putNumber(cellViewModels.count)
                        .localized(),
                    warning: (threadInfo.isNoteToSelf ?
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
                                    cellViewModels
                                        .filter { viewModel in
                                            viewModel.variant.isInfoMessage ||
                                            viewModel.variant.isDeletedMessage
                                        }
                                        .map { $0.id }
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
                                    threadId: threadInfo.id,
                                    threadVariant: threadInfo.variant
                                )
                            ]
                        ),
                        NamedAction(
                            title: (threadInfo.isNoteToSelf ?
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
                                    threadId: threadInfo.id,
                                    threadVariant: threadInfo.variant
                                )
                            ]
                        ),
                        NamedAction(
                            title: (threadInfo.isNoteToSelf ?
                                "deleteMessageDevicesAll".localized() :
                                "deleteMessageEveryone".localized()
                            ),
                            state: .enabled,
                            accessibility: Accessibility(identifier: "Delete for everyone"),
                            behaviours: try deleteForEveryoneBehaviours(
                                isAdmin: isAdmin,
                                threadInfo: threadInfo,
                                authMethod: authMethod,
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
                                    threadId: threadInfo.id,
                                    threadVariant: threadInfo.variant
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
                                    threadId: threadInfo.id,
                                    threadVariant: threadInfo.variant
                                )
                            ]
                        ),
                        NamedAction(
                            title: "deleteMessageEveryone".localized(),
                            state: .enabledAndDefaultSelected,
                            accessibility: Accessibility(identifier: "Delete for everyone"),
                            behaviours: try deleteForEveryoneBehaviours(
                                isAdmin: isAdmin,
                                threadInfo: threadInfo,
                                authMethod: authMethod,
                                cellViewModels: cellViewModels,
                                using: dependencies
                            )
                        )
                    ]
                )
        }
    }
    
    private static func deleteForEveryoneBehaviours(
        isAdmin: Bool,
        threadInfo: ConversationInfoViewModel,
        authMethod: AuthenticationMethod,
        cellViewModels: [MessageViewModel],
        using dependencies: Dependencies
    ) throws -> [Behaviour] {
        /// The non-local deletion behaviours differ depending on the type of conversation
        switch (threadInfo.variant, isAdmin) {
            /// **Note to Self or Contact Conversation**
            /// Delete from all participant devices via an `UnsendRequest` (these will trigger their own sync messages)
            /// Delete from the current users swarm (where possible)
            /// Mark as deleted
            case (.contact, _):
                /// Only include messages sent by the current user (can't delete incoming messages in contact conversations)
                let targetViewModels: [MessageViewModel] = cellViewModels
                    .filter { threadInfo.currentUserSessionIds.contains($0.authorId) }
                let serverHashes: Set<String> = targetViewModels.compactMap { $0.serverHash }.asSet()
                    .inserting(contentsOf: Set(targetViewModels.flatMap { message in
                        message.reactionInfo.compactMap { $0.reaction.serverHash }
                    }))
                let unsendRequests: [Network.PreparedRequest<Void>] = try targetViewModels.map { model in
                    var message: Message = UnsendRequest(
                        timestamp: UInt64(model.timestampMs),
                        author: threadInfo.userSessionId.hexString
                    )
                    .with(
                        expiresInSeconds: model.expiresInSeconds,
                        expiresStartedAtMs: model.expiresStartedAtMs
                    )
                    
                    /// No need to message events because there is no direct UI associated to an `UnsendRequest`
                    return try MessageSender.preparedSend(
                        message: &message,
                        to: .contact(publicKey: model.threadId),
                        namespace: .default,
                        interactionId: nil,
                        attachments: nil,
                        authMethod: authMethod,
                        using: dependencies
                    )
                    .discardingResponse()
                }
                
                /// Batch requests have a limited number of subrequests so make sure to chunk
                /// the unsend requests accordingly
                return [.cancelPendingSendJobs(targetViewModels.map { $0.id })]
                    .appending(
                        contentsOf: try unsendRequests
                            .chunked(by: Network.BatchRequest.Target.storageServer.childRequestLimit)
                            .map { unsendRequestChunk in
                                .preparedRequest(
                                    try Network.StorageServer.preparedBatch(
                                        requests: unsendRequestChunk,
                                        requireAllBatchResponses: false,
                                        swarmPublicKey: threadInfo.id,
                                        using: dependencies
                                    ).discardingResponse()
                                )
                            }
                    )
                    .appending(serverHashes.isEmpty ? nil :
                        .preparedRequest(
                            /// Need to delete the the current users swarm which needs it's own `authMethod`
                            try Network.StorageServer.preparedDeleteMessages(
                                serverHashes: Array(serverHashes),
                                requireSuccessfulDeletion: false,
                                authMethod: try Authentication.with(
                                    swarmPublicKey: threadInfo.userSessionId.hexString,
                                    using: dependencies
                                ),
                                using: dependencies
                            )
                            .discardingResponse()
                        )
                    )
                    .appending(threadInfo.isNoteToSelf ?
                        /// If it's the `Note to Self`conversation then we want to just delete the interaction
                        .deleteFromDatabase(cellViewModels.map { $0.id }) :
                        .markAsDeleted(
                            ids: targetViewModels.map { $0.id },
                            options: [.local, .network],
                            threadId: threadInfo.id,
                            threadVariant: threadInfo.variant
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
                    .filter { isAdmin || threadInfo.currentUserSessionIds.contains($0.authorId) }
                let unsendRequests: [Network.PreparedRequest<Void>] = try targetViewModels.map { model in
                    var message: Message = UnsendRequest(
                        timestamp: UInt64(model.timestampMs),
                        author: (model.variant == .standardOutgoing ?
                            threadInfo.userSessionId.hexString :
                            model.authorId
                        )
                    )
                    .with(
                        expiresInSeconds: model.expiresInSeconds,
                        expiresStartedAtMs: model.expiresStartedAtMs
                    )
                    
                    /// No need to message events because there is no direct UI associated to an `UnsendRequest`
                    return try MessageSender.preparedSend(
                        message: &message,
                        to: .group(publicKey: model.threadId),
                        namespace: .legacyClosedGroup,
                        interactionId: nil,
                        attachments: nil,
                        authMethod: authMethod,
                        using: dependencies
                    )
                    .discardingResponse()
                }
                
                /// Batch requests have a limited number of subrequests so make sure to chunk
                /// the unsend requests accordingly
                return [.cancelPendingSendJobs(targetViewModels.map { $0.id })]
                    .appending(
                        contentsOf: try unsendRequests
                            .chunked(by: Network.BatchRequest.Target.storageServer.childRequestLimit)
                            .map { unsendRequestChunk in
                                .preparedRequest(
                                    try Network.StorageServer.preparedBatch(
                                        requests: unsendRequestChunk,
                                        requireAllBatchResponses: false,
                                        swarmPublicKey: threadInfo.id,
                                        using: dependencies
                                    ).discardingResponse()
                                )
                            }
                    )
                    .appending(
                        .markAsDeleted(
                            ids: targetViewModels.map { $0.id },
                            options: [.local, .network],
                            threadId: threadInfo.id,
                            threadVariant: threadInfo.variant
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
                    .filter { threadInfo.currentUserSessionIds.contains($0.authorId) }
                let serverHashes: Set<String> = targetViewModels.compactMap { $0.serverHash }.asSet()
                    .inserting(contentsOf: Set(targetViewModels.flatMap { message in
                        message.reactionInfo.compactMap { $0.reaction.serverHash }
                    }))
                
                /// **Note:** No signature for member delete content
                let deleteContentSendRequest: Network.PreparedRequest<Void>? = try {
                    guard !serverHashes.isEmpty else { return nil }
                    
                    var message: Message = try GroupUpdateDeleteMemberContentMessage(
                        memberSessionIds: [],
                        messageHashes: Array(serverHashes),
                        sentTimestampMs: dependencies.networkOffsetTimestampMs(),
                        authMethod: nil,
                        using: dependencies
                    )
                    
                    /// No need to message events because there is no direct UI associated to an
                    /// `GroupUpdateDeleteMemberContentMessage`
                    return try MessageSender
                        .preparedSend(
                            message: &message,
                            to: .group(publicKey: threadInfo.id),
                            namespace: .groupMessages,
                            interactionId: nil,
                            attachments: nil,
                            authMethod: authMethod,
                            using: dependencies
                        )
                        .discardingResponse()
                }()
                
                return [.cancelPendingSendJobs(targetViewModels.map { $0.id })]
                    .appending(deleteContentSendRequest.map { .preparedRequest($0) })
                    .appending(
                        .markAsDeleted(
                            ids: targetViewModels.map { $0.id },
                            options: [.local, .network],
                            threadId: threadInfo.id,
                            threadVariant: threadInfo.variant
                        )
                    )
                
            /// **Group Conversation for Admin**
            /// Delete from all participant devices via an `GroupUpdateDeleteMemberContentMessage`
            /// Delete from the group swarm
            /// Mark as deleted
            case (.group, true):
                guard
                    let ed25519SecretKey: [UInt8] = dependencies.mutate(cache: .libSession, { cache in
                        cache.secretKey(groupSessionId: SessionId(.group, hex: threadInfo.id))
                    })
                else {
                    Log.error("[ConversationViewModel] Failed to retrieve groupIdentityPrivateKey when trying to delete messages from group.")
                    throw StorageError.objectNotFound
                }
                
                /// Only try to delete messages with server hashes (can't delete them otherwise)
                let serverHashes: Set<String> = cellViewModels.compactMap { $0.serverHash }.asSet()
                    .inserting(contentsOf: Set(cellViewModels.flatMap { message in
                        message.reactionInfo.compactMap { $0.reaction.serverHash }
                    }))
                let deleteContentSendRequest: Network.PreparedRequest<Void>? = try {
                    guard !serverHashes.isEmpty else { return nil }
                    
                    var message: Message = try GroupUpdateDeleteMemberContentMessage(
                        memberSessionIds: [],
                        messageHashes: Array(serverHashes),
                        sentTimestampMs: dependencies.networkOffsetTimestampMs(),
                        authMethod: Authentication.groupAdmin(
                            groupSessionId: SessionId(.group, hex: threadInfo.id),
                            ed25519SecretKey: ed25519SecretKey
                        ),
                        using: dependencies
                    )
                    
                    /// No need to message events because there is no direct UI associated to an
                    /// `GroupUpdateDeleteMemberContentMessage`
                    return try MessageSender
                        .preparedSend(
                            message: &message,
                            to: .group(publicKey: threadInfo.id),
                            namespace: .groupMessages,
                            interactionId: nil,
                            attachments: nil,
                            authMethod: authMethod,
                            using: dependencies
                        )
                        .discardingResponse()
                }()
                
                return [.cancelPendingSendJobs(cellViewModels.map { $0.id })]
                    .appending(deleteContentSendRequest.map { .preparedRequest($0) })
                    .appending(serverHashes.isEmpty ? nil :
                            .preparedRequest(try Network.StorageServer
                            .preparedDeleteMessages(
                                serverHashes: Array(serverHashes),
                                requireSuccessfulDeletion: false,
                                authMethod: Authentication.groupAdmin(
                                    groupSessionId: SessionId(.group, hex: threadInfo.id),
                                    ed25519SecretKey: Array(ed25519SecretKey)
                                ),
                                using: dependencies
                            )
                            .discardingResponse())
                    )
                    .appending(
                        .markAsDeleted(
                            ids: cellViewModels.map { $0.id },
                            options: [.local, .network],
                            threadId: threadInfo.id,
                            threadVariant: threadInfo.variant
                        )
                    )
            
            /// **Community Conversation**
            /// Delete from the SOGS
            /// Delete from the current device
            ///
            /// **Note:** To simplify the logic (since the sender is a blinded id) we don't bother doing admin/sender checks here
            /// and just rely on the UI state or the SOGS server (if the UI allows an invalid case) to prevent invalid behaviours
            case (.community, _):
                guard let roomToken: String = threadInfo.communityInfo?.roomToken else {
                    Log.error("[ConversationViewModel] Failed to retrieve community info when trying to delete messages.")
                    throw StorageError.objectNotFound
                }
                
                let deleteRequests: [Network.PreparedRequest] = try cellViewModels
                    .compactMap { $0.openGroupServerMessageId }
                    .map { messageId in
                        try Network.SOGS.preparedMessageDelete(
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
                            .chunked(by: Network.BatchRequest.Target.storageServer.childRequestLimit)
                            .map { deleteRequestsChunk in
                                .preparedRequest(
                                    try Network.SOGS.preparedBatch(
                                        requests: deleteRequestsChunk,
                                        authMethod: authMethod,
                                        using: dependencies
                                    )
                                    .discardingResponse()
                                )
                            }
                    )
                    .appending(
                        .deleteFromDatabase(cellViewModels.map { $0.id })
                    )
        }
    }
}
