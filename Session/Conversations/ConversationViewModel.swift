// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import DifferenceKit
import SessionMessagingKit
import SessionUtilitiesKit

public class ConversationViewModel: OWSAudioPlayerDelegate {
    public typealias SectionModel = ArraySection<Section, MessageViewModel>
    
    // MARK: - FocusBehaviour
    
    public enum FocusBehaviour {
        case none
        case highlight
    }
    
    // MARK: - Action
    
    public enum Action {
        case none
        case compose
        case audioCall
        case videoCall
    }
    
    // MARK: - Section
    
    public enum Section: Differentiable, Equatable, Comparable, Hashable {
        case loadOlder
        case messages
        case loadNewer
    }
    
    // MARK: - Variables
    
    public static let pageSize: Int = 50
    
    private var threadId: String
    public let initialThreadVariant: SessionThread.Variant
    public var sentMessageBeforeUpdate: Bool = false
    public var lastSearchedText: String?
    public let focusedInteractionInfo: Interaction.TimestampInfo? // Note: This is used for global search
    public let focusBehaviour: FocusBehaviour
    private let initialUnreadInteractionId: Int64?
    
    public lazy var blockedBannerMessage: String = {
        switch self.threadData.threadVariant {
            case .contact:
                let name: String = Profile.displayName(
                    id: self.threadData.threadId,
                    threadVariant: self.threadData.threadVariant
                )
                
                return "\(name) is blocked. Unblock them?"
                
            default: return "Thread is blocked. Unblock it?"
        }
    }()
    
    // MARK: - Initialization
    
    init(threadId: String, threadVariant: SessionThread.Variant, focusedInteractionInfo: Interaction.TimestampInfo?) {
        typealias InitialData = (
            currentUserPublicKey: String,
            initialUnreadInteractionInfo: Interaction.TimestampInfo?,
            threadIsBlocked: Bool,
            currentUserIsClosedGroupMember: Bool?,
            openGroupPermissions: OpenGroup.Permissions?,
            blindedKey: String?
        )
        
        let initialData: InitialData? = Storage.shared.read { db -> InitialData in
            let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
            let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
            let currentUserPublicKey: String = getUserHexEncodedPublicKey(db)
            
            // If we have a specified 'focusedInteractionInfo' then use that, otherwise retrieve the oldest
            // unread interaction and start focused around that one
            let initialUnreadInteractionInfo: Interaction.TimestampInfo? = try Interaction
                .select(.id, .timestampMs)
                .filter(interaction[.wasRead] == false)
                .filter(interaction[.threadId] == threadId)
                .order(interaction[.timestampMs].asc)
                .asRequest(of: Interaction.TimestampInfo.self)
                .fetchOne(db)
            let threadIsBlocked: Bool = (threadVariant != .contact ? false :
                try Contact
                    .filter(id: threadId)
                    .select(.isBlocked)
                    .asRequest(of: Bool.self)
                    .fetchOne(db)
                    .defaulting(to: false)
            )
            let currentUserIsClosedGroupMember: Bool? = (![.legacyGroup, .group].contains(threadVariant) ? nil :
                GroupMember
                    .filter(groupMember[.groupId] == threadId)
                    .filter(groupMember[.profileId] == currentUserPublicKey)
                    .filter(groupMember[.role] == GroupMember.Role.standard)
                    .isNotEmpty(db)
            )
            let openGroupPermissions: OpenGroup.Permissions? = (threadVariant != .community ? nil :
                try OpenGroup
                    .filter(id: threadId)
                    .select(.permissions)
                    .asRequest(of: OpenGroup.Permissions.self)
                    .fetchOne(db)
            )
            let blindedKey: String? = SessionThread.getUserHexEncodedBlindedKey(
                db,
                threadId: threadId,
                threadVariant: threadVariant
            )
            
            return (
                currentUserPublicKey,
                initialUnreadInteractionInfo,
                threadIsBlocked,
                currentUserIsClosedGroupMember,
                openGroupPermissions,
                blindedKey
            )
        }
        
        self.threadId = threadId
        self.initialThreadVariant = threadVariant
        self.focusedInteractionInfo = (focusedInteractionInfo ?? initialData?.initialUnreadInteractionInfo)
        self.focusBehaviour = (focusedInteractionInfo == nil ? .none : .highlight)
        self.initialUnreadInteractionId = initialData?.initialUnreadInteractionInfo?.id
        self.threadData = SessionThreadViewModel(
            threadId: threadId,
            threadVariant: threadVariant,
            threadIsNoteToSelf: (initialData?.currentUserPublicKey == threadId),
            threadIsBlocked: initialData?.threadIsBlocked,
            currentUserIsClosedGroupMember: initialData?.currentUserIsClosedGroupMember,
            openGroupPermissions: initialData?.openGroupPermissions
        ).populatingCurrentUserBlindedKey(currentUserBlindedPublicKeyForThisThread: initialData?.blindedKey)
        self.pagedDataObserver = nil
        
        // Note: Since this references self we need to finish initializing before setting it, we
        // also want to skip the initial query and trigger it async so that the push animation
        // doesn't stutter (it should load basically immediately but without this there is a
        // distinct stutter)
        self.pagedDataObserver = self.setupPagedObserver(
            for: threadId,
            userPublicKey: (initialData?.currentUserPublicKey ?? getUserHexEncodedPublicKey()),
            blindedPublicKey: SessionThread.getUserHexEncodedBlindedKey(
                threadId: threadId,
                threadVariant: threadVariant
            )
        )
        
        // Run the initial query on a background thread so we don't block the push transition
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // If we don't have a `initialFocusedInfo` then default to `.pageBefore` (it'll query
            // from a `0` offset)
            guard let initialFocusedInfo: Interaction.TimestampInfo = (focusedInteractionInfo ?? initialData?.initialUnreadInteractionInfo) else {
                self?.pagedDataObserver?.load(.pageBefore)
                return
            }
            
            self?.pagedDataObserver?.load(.initialPageAround(id: initialFocusedInfo.id))
        }
    }
    
    // MARK: - Thread Data
    
    /// This value is the current state of the view
    public private(set) var threadData: SessionThreadViewModel
    
    /// This is all the data the screen needs to populate itself, please see the following link for tips to help optimise
    /// performance https://github.com/groue/GRDB.swift#valueobservation-performance
    ///
    /// **Note:** The 'trackingConstantRegion' is optimised in such a way that the request needs to be static
    /// otherwise there may be situations where it doesn't get updates, this means we can't have conditional queries
    ///
    /// **Note:** This observation will be triggered twice immediately (and be de-duped by the `removeDuplicates`)
    /// this is due to the behaviour of `ValueConcurrentObserver.asyncStartObservation` which triggers it's own
    /// fetch (after the ones in `ValueConcurrentObserver.asyncStart`/`ValueConcurrentObserver.syncStart`)
    /// just in case the database has changed between the two reads - unfortunately it doesn't look like there is a way to prevent this
    public typealias ThreadObservation = ValueObservation<ValueReducers.Trace<ValueReducers.RemoveDuplicates<ValueReducers.Fetch<SessionThreadViewModel?>>>>
    public lazy var observableThreadData: ThreadObservation = setupObservableThreadData(for: self.threadId)
    
    private func setupObservableThreadData(for threadId: String) -> ThreadObservation {
        return ValueObservation
            .trackingConstantRegion { [weak self] db -> SessionThreadViewModel? in
                let userPublicKey: String = getUserHexEncodedPublicKey(db)
                let recentReactionEmoji: [String] = try Emoji.getRecent(db, withDefaultEmoji: true)
                let threadViewModel: SessionThreadViewModel? = try SessionThreadViewModel
                    .conversationQuery(threadId: threadId, userPublicKey: userPublicKey)
                    .fetchOne(db)
                
                return threadViewModel
                    .map { $0.with(recentReactionEmoji: recentReactionEmoji) }
                    .map { viewModel -> SessionThreadViewModel in
                        viewModel.populatingCurrentUserBlindedKey(
                            db,
                            currentUserBlindedPublicKeyForThisThread: self?.threadData.currentUserBlindedPublicKey
                        )
                    }
            }
            .removeDuplicates()
            .handleEvents(didFail: { SNLog("[ConversationViewModel] Observation failed with error: \($0)") })
    }

    public func updateThreadData(_ updatedData: SessionThreadViewModel) {
        self.threadData = updatedData
    }
    
    // MARK: - Interaction Data
    
    private var lastInteractionTimestampMsMarkedAsRead: Int64 = 0
    public private(set) var unobservedInteractionDataChanges: ([SectionModel], StagedChangeset<[SectionModel]>)?
    public private(set) var interactionData: [SectionModel] = []
    public private(set) var reactionExpandedInteractionIds: Set<Int64> = []
    public private(set) var pagedDataObserver: PagedDatabaseObserver<Interaction, MessageViewModel>?
    
    public var onInteractionChange: (([SectionModel], StagedChangeset<[SectionModel]>) -> ())? {
        didSet {
            // When starting to observe interaction changes we want to trigger a UI update just in case the
            // data was changed while we weren't observing
            if let changes: ([SectionModel], StagedChangeset<[SectionModel]>) = self.unobservedInteractionDataChanges {
                let performChange: (([SectionModel], StagedChangeset<[SectionModel]>) -> ())? = onInteractionChange
                
                switch Thread.isMainThread {
                    case true: performChange?(changes.0, changes.1)
                    case false: DispatchQueue.main.async { performChange?(changes.0, changes.1) }
                }
                
                self.unobservedInteractionDataChanges = nil
            }
        }
    }
    
    private func setupPagedObserver(for threadId: String, userPublicKey: String, blindedPublicKey: String?) -> PagedDatabaseObserver<Interaction, MessageViewModel> {
        return PagedDatabaseObserver(
            pagedTable: Interaction.self,
            pageSize: ConversationViewModel.pageSize,
            idColumn: .id,
            observedChanges: [
                PagedData.ObservedChanges(
                    table: Interaction.self,
                    columns: Interaction.Columns
                        .allCases
                        .filter { $0 != .wasRead }
                ),
                PagedData.ObservedChanges(
                    table: Contact.self,
                    columns: [.isTrusted],
                    joinToPagedType: {
                        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                        let contact: TypedTableAlias<Contact> = TypedTableAlias()
                        
                        return SQL("JOIN \(Contact.self) ON \(contact[.id]) = \(interaction[.threadId])")
                    }()
                ),
                PagedData.ObservedChanges(
                    table: Profile.self,
                    columns: [.profilePictureFileName],
                    joinToPagedType: {
                        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                        let profile: TypedTableAlias<Profile> = TypedTableAlias()
                        
                        return SQL("JOIN \(Profile.self) ON \(profile[.id]) = \(interaction[.authorId])")
                    }()
                ),
                PagedData.ObservedChanges(
                    table: RecipientState.self,
                    columns: [.state, .readTimestampMs, .mostRecentFailureText],
                    joinToPagedType: {
                        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
                        let recipientState: TypedTableAlias<RecipientState> = TypedTableAlias()
                        
                        return SQL("LEFT JOIN \(RecipientState.self) ON \(recipientState[.interactionId]) = \(interaction[.id])")
                    }()
                ),
            ],
            filterSQL: MessageViewModel.filterSQL(threadId: threadId),
            groupSQL: MessageViewModel.groupSQL,
            orderSQL: MessageViewModel.orderSQL,
            dataQuery: MessageViewModel.baseQuery(
                userPublicKey: userPublicKey,
                blindedPublicKey: blindedPublicKey,
                orderSQL: MessageViewModel.orderSQL,
                groupSQL: MessageViewModel.groupSQL
            ),
            associatedRecords: [
                AssociatedRecord<MessageViewModel.AttachmentInteractionInfo, MessageViewModel>(
                    trackedAgainst: Attachment.self,
                    observedChanges: [
                        PagedData.ObservedChanges(
                            table: Attachment.self,
                            columns: [.state]
                        )
                    ],
                    dataQuery: MessageViewModel.AttachmentInteractionInfo.baseQuery,
                    joinToPagedType: MessageViewModel.AttachmentInteractionInfo.joinToViewModelQuerySQL,
                    associateData: MessageViewModel.AttachmentInteractionInfo.createAssociateDataClosure()
                ),
                AssociatedRecord<MessageViewModel.ReactionInfo, MessageViewModel>(
                    trackedAgainst: Reaction.self,
                    observedChanges: [
                        PagedData.ObservedChanges(
                            table: Reaction.self,
                            columns: [.count]
                        )
                    ],
                    dataQuery: MessageViewModel.ReactionInfo.baseQuery,
                    joinToPagedType: MessageViewModel.ReactionInfo.joinToViewModelQuerySQL,
                    associateData: MessageViewModel.ReactionInfo.createAssociateDataClosure()
                ),
                AssociatedRecord<MessageViewModel.TypingIndicatorInfo, MessageViewModel>(
                    trackedAgainst: ThreadTypingIndicator.self,
                    observedChanges: [
                        PagedData.ObservedChanges(
                            table: ThreadTypingIndicator.self,
                            events: [.insert, .delete],
                            columns: []
                        )
                    ],
                    dataQuery: MessageViewModel.TypingIndicatorInfo.baseQuery,
                    joinToPagedType: MessageViewModel.TypingIndicatorInfo.joinToViewModelQuerySQL,
                    associateData: MessageViewModel.TypingIndicatorInfo.createAssociateDataClosure()
                )
            ],
            onChangeUnsorted: { [weak self] updatedData, updatedPageInfo in
                self?.resolveOptimisticUpdates(with: updatedData)
                
                PagedData.processAndTriggerUpdates(
                    updatedData: self?.process(
                        data: updatedData,
                        for: updatedPageInfo,
                        optimisticMessages: (self?.optimisticallyInsertedMessages.wrappedValue.values)
                            .map { Array($0) },
                        initialUnreadInteractionId: self?.initialUnreadInteractionId
                    ),
                    currentDataRetriever: { self?.interactionData },
                    onDataChange: self?.onInteractionChange,
                    onUnobservedDataChange: { updatedData, changeset in
                        self?.unobservedInteractionDataChanges = (changeset.isEmpty ?
                            nil :
                            (updatedData, changeset)
                        )
                    }
                )
            }
        )
    }
    
    private func process(
        data: [MessageViewModel],
        for pageInfo: PagedData.PageInfo,
        optimisticMessages: [MessageViewModel]?,
        initialUnreadInteractionId: Int64?
    ) -> [SectionModel] {
        let typingIndicator: MessageViewModel? = data.first(where: { $0.isTypingIndicator == true })
        let sortedData: [MessageViewModel] = data
            .appending(contentsOf: (optimisticMessages ?? []))
            .filter { !$0.cellType.isPostProcessed }
            .sorted { lhs, rhs -> Bool in lhs.timestampMs < rhs.timestampMs }
        
        // We load messages from newest to oldest so having a pageOffset larger than zero means
        // there are newer pages to load
        return [
            (!data.isEmpty && (pageInfo.pageOffset + pageInfo.currentCount) < pageInfo.totalCount ?
                [SectionModel(section: .loadOlder)] :
                []
            ),
            [
                SectionModel(
                    section: .messages,
                    elements: sortedData
                        .enumerated()
                        .map { index, cellViewModel -> MessageViewModel in
                            cellViewModel.withClusteringChanges(
                                prevModel: (index > 0 ? sortedData[index - 1] : nil),
                                nextModel: (index < (sortedData.count - 1) ? sortedData[index + 1] : nil),
                                isLast: (
                                    // The database query sorts by timestampMs descending so the "last"
                                    // interaction will actually have a 'pageOffset' of '0' even though
                                    // it's the last element in the 'sortedData' array
                                    index == (sortedData.count - 1) &&
                                    pageInfo.pageOffset == 0
                                ),
                                isLastOutgoing: (
                                    cellViewModel.id == sortedData
                                        .filter {
                                            $0.authorId == threadData.currentUserPublicKey ||
                                            $0.authorId == threadData.currentUserBlindedPublicKey
                                        }
                                        .last?
                                        .id
                                ),
                                currentUserBlindedPublicKey: threadData.currentUserBlindedPublicKey
                            )
                        }
                        .reduce([]) { result, message in
                            let updatedResult: [MessageViewModel] = result
                                .appending(initialUnreadInteractionId == nil || message.id != initialUnreadInteractionId ?
                                   nil :
                                    MessageViewModel(
                                        timestampMs: message.timestampMs,
                                        cellType: .unreadMarker
                                    )
                            )
                            
                            guard message.shouldShowDateHeader else {
                                return updatedResult.appending(message)
                            }
                            
                            return updatedResult
                                .appending(
                                    MessageViewModel(
                                        timestampMs: message.timestampMs,
                                        cellType: .dateHeader
                                    )
                                )
                                .appending(message)
                        }
                        .appending(typingIndicator)
                )
            ],
            (!data.isEmpty && pageInfo.pageOffset > 0 ?
                [SectionModel(section: .loadNewer)] :
                []
            )
        ].flatMap { $0 }
    }
    
    public func updateInteractionData(_ updatedData: [SectionModel]) {
        self.interactionData = updatedData
    }
    
    // MARK: - Optimistic Message Handling
    
    public typealias OptimisticMessageData = (
        id: UUID,
        interaction: Interaction,
        attachmentData: Attachment.PreparedData?,
        linkPreviewAttachment: Attachment?
    )
    
    private var optimisticallyInsertedMessages: Atomic<[UUID: MessageViewModel]> = Atomic([:])
    private var optimisticMessageAssociatedInteractionIds: Atomic<[Int64: UUID]> = Atomic([:])
    
    public func optimisticallyAppendOutgoingMessage(
        text: String?,
        sentTimestampMs: Int64,
        attachments: [SignalAttachment]?,
        linkPreviewDraft: LinkPreviewDraft?,
        quoteModel: QuotedReplyModel?
    ) -> OptimisticMessageData {
        // Generate the optimistic data
        let optimisticMessageId: UUID = UUID()
        let currentUserProfile: Profile = Profile.fetchOrCreateCurrentUser()
        let interaction: Interaction = Interaction(
            threadId: threadData.threadId,
            authorId: (threadData.currentUserBlindedPublicKey ?? threadData.currentUserPublicKey),
            variant: .standardOutgoing,
            body: text,
            timestampMs: sentTimestampMs,
            hasMention: Interaction.isUserMentioned(
                publicKeysToCheck: [
                    threadData.currentUserPublicKey,
                    threadData.currentUserBlindedPublicKey
                ].compactMap { $0 },
                body: text
            ),
            linkPreviewUrl: linkPreviewDraft?.urlString
        )
        let optimisticAttachments: Attachment.PreparedData? = attachments
            .map { Attachment.prepare(attachments: $0) }
        let linkPreviewAttachment: Attachment? = linkPreviewDraft.map { draft in
            try? LinkPreview.generateAttachmentIfPossible(
                imageData: draft.jpegImageData,
                mimeType: OWSMimeTypeImageJpeg
            )
        }
        let optimisticData: OptimisticMessageData = (
            optimisticMessageId,
            interaction,
            optimisticAttachments,
            linkPreviewAttachment
        )
        
        // Generate the actual 'MessageViewModel'
        let messageViewModel: MessageViewModel = MessageViewModel(
            threadId: threadData.threadId,
            threadVariant: threadData.threadVariant,
            threadHasDisappearingMessagesEnabled: (threadData.disappearingMessagesConfiguration?.isEnabled ?? false),
            threadOpenGroupServer: threadData.openGroupServer,
            threadOpenGroupPublicKey: threadData.openGroupPublicKey,
            threadContactNameInternal: threadData.threadContactName(),
            timestampMs: interaction.timestampMs,
            receivedAtTimestampMs: interaction.receivedAtTimestampMs,
            authorId: interaction.authorId,
            authorNameInternal: currentUserProfile.displayName(),
            body: interaction.body,
            expiresStartedAtMs: interaction.expiresStartedAtMs,
            expiresInSeconds: interaction.expiresInSeconds,
            isSenderOpenGroupModerator: OpenGroupManager.isUserModeratorOrAdmin(
                threadData.currentUserPublicKey,
                for: threadData.openGroupRoomToken,
                on: threadData.openGroupServer
            ),
            currentUserProfile: currentUserProfile,
            quote: quoteModel.map { model in
                // Don't care about this optimistic quote (the proper one will be generated in the database)
                Quote(
                    interactionId: -1,    // Can't save to db optimistically
                    authorId: model.authorId,
                    timestampMs: model.timestampMs,
                    body: model.body,
                    attachmentId: model.attachment?.id
                )
            },
            quoteAttachment: quoteModel?.attachment,
            linkPreview: linkPreviewDraft.map { draft in
                LinkPreview(
                    url: draft.urlString,
                    title: draft.title,
                    attachmentId: nil    // Can't save to db optimistically
                )
            },
            linkPreviewAttachment: linkPreviewAttachment,
            attachments: optimisticAttachments?.attachments
        )
        
        optimisticallyInsertedMessages.mutate { $0[optimisticMessageId] = messageViewModel }
        
        // If we can't get the current page data then don't bother trying to update (it's not going to work)
        guard let currentPageInfo: PagedData.PageInfo = self.pagedDataObserver?.pageInfo.wrappedValue else {
            return optimisticData
        }
        
        /// **MUST** have the same logic as in the 'PagedDataObserver.onChangeUnsorted' above
        let currentData: [SectionModel] = (unobservedInteractionDataChanges?.0 ?? interactionData)
        
        PagedData.processAndTriggerUpdates(
            updatedData: process(
                data: (currentData.first(where: { $0.model == .messages })?.elements ?? []),
                for: currentPageInfo,
                optimisticMessages: Array(optimisticallyInsertedMessages.wrappedValue.values),
                initialUnreadInteractionId: initialUnreadInteractionId
            ),
            currentDataRetriever: { [weak self] in self?.interactionData },
            onDataChange: self.onInteractionChange,
            onUnobservedDataChange: { [weak self] updatedData, changeset in
                self?.unobservedInteractionDataChanges = (changeset.isEmpty ?
                    nil :
                    (updatedData, changeset)
                )
            }
        )
        
        return optimisticData
    }
    
    /// Record an association between an `optimisticMessageId` and a specific `interactionId`
    public func associate(optimisticMessageId: UUID, to interactionId: Int64?) {
        guard let interactionId: Int64 = interactionId else { return }
        
        optimisticMessageAssociatedInteractionIds.mutate { $0[interactionId] = optimisticMessageId }
    }
    
    /// Remove any optimisticUpdate entries which have an associated interactionId in the provided data
    private func resolveOptimisticUpdates(with data: [MessageViewModel]) {
        let interactionIds: [Int64] = data.map { $0.id }
        let idsToRemove: [UUID] = optimisticMessageAssociatedInteractionIds
            .mutate { associatedIds in interactionIds.compactMap { associatedIds.removeValue(forKey: $0) } }
        
        optimisticallyInsertedMessages.mutate { messages in idsToRemove.forEach { messages.removeValue(forKey: $0) } }
    }
    
    // MARK: - Mentions
    
    public func mentions(for query: String = "") -> [MentionInfo] {
        let threadData: SessionThreadViewModel = self.threadData
        
        return Storage.shared
            .read { db -> [MentionInfo] in
                let userPublicKey: String = getUserHexEncodedPublicKey(db)
                let pattern: FTS5Pattern? = try? SessionThreadViewModel.pattern(db, searchTerm: query, forTable: Profile.self)
                let capabilities: Set<Capability.Variant> = (threadData.threadVariant != .community ?
                    nil :
                    try? Capability
                        .select(.variant)
                        .filter(Capability.Columns.openGroupServer == threadData.openGroupServer)
                        .asRequest(of: Capability.Variant.self)
                        .fetchSet(db)
                )
                .defaulting(to: [])
                let targetPrefix: SessionId.Prefix = (capabilities.contains(.blind) ?
                    .blinded :
                    .standard
                )
                
                return (try MentionInfo
                    .query(
                        userPublicKey: userPublicKey,
                        threadId: threadData.threadId,
                        threadVariant: threadData.threadVariant,
                        targetPrefix: targetPrefix,
                        pattern: pattern
                    )?
                    .fetchAll(db))
                    .defaulting(to: [])
            }
            .defaulting(to: [])
    }
    
    // MARK: - Functions
    
    public func updateDraft(to draft: String) {
        let threadId: String = self.threadId
        let currentDraft: String = Storage.shared
            .read { db in
                try SessionThread
                    .select(.messageDraft)
                    .filter(id: threadId)
                    .asRequest(of: String.self)
                    .fetchOne(db)
            }
            .defaulting(to: "")
        
        // Only write the updated draft to the database if it's changed (avoid unnecessary writes)
        guard draft != currentDraft else { return }
        
        Storage.shared.writeAsync { db in
            try SessionThread
                .filter(id: threadId)
                .updateAll(db, SessionThread.Columns.messageDraft.set(to: draft))
        }
    }
    
    /// This method marks a thread as read and depending on the target may also update the interactions within a thread as read
    public func markAsRead(
        target: SessionThreadViewModel.ReadTarget,
        timestampMs: Int64?
    ) {
        /// Since this method now gets triggered when scrolling we want to try to optimise it and avoid busying the database
        /// write queue when it isn't needed, in order to do this we don't bother marking anything as read if this was called with
        /// the same `interactionId` that we previously marked as read (ie. when scrolling and the last message hasn't changed)
        ///
        /// The `ThreadViewModel.markAsRead` method also tries to avoid marking as read if a conversation is already fully read
        switch target {
            case .thread: self.threadData.markAsRead(target: target)
            case .threadAndInteractions:
                guard
                    timestampMs == nil ||
                    self.lastInteractionTimestampMsMarkedAsRead < (timestampMs ?? 0)
                else {
                    self.threadData.markAsRead(target: .thread)
                    return
                }
                
                // If we were given a timestamp then update the 'lastInteractionTimestampMsMarkedAsRead'
                // to avoid needless updates
                if let timestampMs: Int64 = timestampMs {
                    self.lastInteractionTimestampMsMarkedAsRead = timestampMs
                }
                
                self.threadData.markAsRead(target: target)
        }
    }
    
    public func swapToThread(updatedThreadId: String) {
        let oldestMessageId: Int64? = self.interactionData
            .filter { $0.model == .messages }
            .first?
            .elements
            .first?
            .id
        
        self.threadId = updatedThreadId
        self.observableThreadData = self.setupObservableThreadData(for: updatedThreadId)
        self.pagedDataObserver = self.setupPagedObserver(
            for: updatedThreadId,
            userPublicKey: getUserHexEncodedPublicKey(),
            blindedPublicKey: nil
        )
        
        // Try load everything up to the initial visible message, fallback to just the initial page of messages
        // if we don't have one
        switch oldestMessageId {
            case .some(let id): self.pagedDataObserver?.load(.untilInclusive(id: id, padding: 0))
            case .none: self.pagedDataObserver?.load(.pageBefore)
        }
    }
    
    public func trustContact() {
        guard self.threadData.threadVariant == .contact else { return }
        
        let threadId: String = self.threadId
        
        Storage.shared.writeAsync { db in
            try Contact
                .filter(id: threadId)
                .updateAll(db, Contact.Columns.isTrusted.set(to: true))
            
            // Start downloading any pending attachments for this contact (UI will automatically be
            // updated due to the database observation)
            try Attachment
                .stateInfo(authorId: threadId, state: .pendingDownload)
                .fetchAll(db)
                .forEach { attachmentDownloadInfo in
                    JobRunner.add(
                        db,
                        job: Job(
                            variant: .attachmentDownload,
                            threadId: threadId,
                            interactionId: attachmentDownloadInfo.interactionId,
                            details: AttachmentDownloadJob.Details(
                                attachmentId: attachmentDownloadInfo.attachmentId
                            )
                        )
                    )
                }
        }
    }
    
    public func unblockContact() {
        guard self.threadData.threadVariant == .contact else { return }
        
        let threadId: String = self.threadId
        
        Storage.shared.writeAsync { db in
            try Contact
                .filter(id: threadId)
                .updateAllAndConfig(db, Contact.Columns.isBlocked.set(to: false))
        }
    }
    
    public func expandReactions(for interactionId: Int64) {
        reactionExpandedInteractionIds.insert(interactionId)
    }
    
    public func collapseReactions(for interactionId: Int64) {
        reactionExpandedInteractionIds.remove(interactionId)
    }
    
    // MARK: - Audio Playback
    
    public struct PlaybackInfo {
        let state: AudioPlaybackState
        let progress: TimeInterval
        let playbackRate: Double
        let oldPlaybackRate: Double
        let updateCallback: (PlaybackInfo?, Error?) -> ()
        
        public func with(
            state: AudioPlaybackState? = nil,
            progress: TimeInterval? = nil,
            playbackRate: Double? = nil,
            updateCallback: ((PlaybackInfo?, Error?) -> ())? = nil
        ) -> PlaybackInfo {
            return PlaybackInfo(
                state: (state ?? self.state),
                progress: (progress ?? self.progress),
                playbackRate: (playbackRate ?? self.playbackRate),
                oldPlaybackRate: self.playbackRate,
                updateCallback: (updateCallback ?? self.updateCallback)
            )
        }
    }
    
    private var audioPlayer: Atomic<OWSAudioPlayer?> = Atomic(nil)
    private var currentPlayingInteraction: Atomic<Int64?> = Atomic(nil)
    private var playbackInfo: Atomic<[Int64: PlaybackInfo]> = Atomic([:])
    
    public func playbackInfo(for viewModel: MessageViewModel, updateCallback: ((PlaybackInfo?, Error?) -> ())? = nil) -> PlaybackInfo? {
        // Use the existing info if it already exists (update it's callback if provided as that means
        // the cell was reloaded)
        if let currentPlaybackInfo: PlaybackInfo = playbackInfo.wrappedValue[viewModel.id] {
            let updatedPlaybackInfo: PlaybackInfo = currentPlaybackInfo
                .with(updateCallback: updateCallback)
            
            playbackInfo.mutate { $0[viewModel.id] = updatedPlaybackInfo }
            
            return updatedPlaybackInfo
        }
        
        // Validate the item is a valid audio item
        guard
            let updateCallback: ((PlaybackInfo?, Error?) -> ()) = updateCallback,
            let attachment: Attachment = viewModel.attachments?.first,
            attachment.isAudio,
            attachment.isValid,
            let originalFilePath: String = attachment.originalFilePath,
            FileManager.default.fileExists(atPath: originalFilePath)
        else { return nil }
        
        // Create the info with the update callback
        let newPlaybackInfo: PlaybackInfo = PlaybackInfo(
            state: .stopped,
            progress: 0,
            playbackRate: 1,
            oldPlaybackRate: 1,
            updateCallback: updateCallback
        )
        
        // Cache the info
        playbackInfo.mutate { $0[viewModel.id] = newPlaybackInfo }
        
        return newPlaybackInfo
    }
    
    public func playOrPauseAudio(for viewModel: MessageViewModel) {
        guard
            let attachment: Attachment = viewModel.attachments?.first,
            let originalFilePath: String = attachment.originalFilePath,
            FileManager.default.fileExists(atPath: originalFilePath)
        else { return }
        
        // If the user interacted with the currently playing item
        guard currentPlayingInteraction.wrappedValue != viewModel.id else {
            let currentPlaybackInfo: PlaybackInfo? = playbackInfo.wrappedValue[viewModel.id]
            let updatedPlaybackInfo: PlaybackInfo? = currentPlaybackInfo?
                .with(
                    state: (currentPlaybackInfo?.state != .playing ? .playing : .paused),
                    playbackRate: 1
                )
            
            audioPlayer.wrappedValue?.playbackRate = 1
            
            switch currentPlaybackInfo?.state {
                case .playing: audioPlayer.wrappedValue?.pause()
                default: audioPlayer.wrappedValue?.play()
            }
            
            // Update the state and then update the UI with the updated state
            playbackInfo.mutate { $0[viewModel.id] = updatedPlaybackInfo }
            updatedPlaybackInfo?.updateCallback(updatedPlaybackInfo, nil)
            return
        }
        
        // First stop any existing audio
        audioPlayer.wrappedValue?.stop()
        
        // Then setup the state for the new audio
        currentPlayingInteraction.mutate { $0 = viewModel.id }
        
        let currentPlaybackTime: TimeInterval? = playbackInfo.wrappedValue[viewModel.id]?.progress
        audioPlayer.mutate { [weak self] player in
            // Note: We clear the delegate and explicitly set to nil here as when the OWSAudioPlayer
            // gets deallocated it triggers state changes which cause UI bugs when auto-playing
            player?.delegate = nil
            player = nil
            
            let audioPlayer: OWSAudioPlayer = OWSAudioPlayer(
                mediaUrl: URL(fileURLWithPath: originalFilePath),
                audioBehavior: .audioMessagePlayback,
                delegate: self
            )
            audioPlayer.play()
            audioPlayer.setCurrentTime(currentPlaybackTime ?? 0)
            player = audioPlayer
        }
    }
    
    public func speedUpAudio(for viewModel: MessageViewModel) {
        // If we aren't playing the specified item then just start playing it
        guard viewModel.id == currentPlayingInteraction.wrappedValue else {
            playOrPauseAudio(for: viewModel)
            return
        }
        
        let updatedPlaybackInfo: PlaybackInfo? = playbackInfo.wrappedValue[viewModel.id]?
            .with(playbackRate: 1.5)
        
        // Speed up the audio player
        audioPlayer.wrappedValue?.playbackRate = 1.5
        
        playbackInfo.mutate { $0[viewModel.id] = updatedPlaybackInfo }
        updatedPlaybackInfo?.updateCallback(updatedPlaybackInfo, nil)
    }
    
    public func stopAudio() {
        audioPlayer.wrappedValue?.stop()
        
        currentPlayingInteraction.mutate { $0 = nil }
        audioPlayer.mutate {
            // Note: We clear the delegate and explicitly set to nil here as when the OWSAudioPlayer
            // gets deallocated it triggers state changes which cause UI bugs when auto-playing
            $0?.delegate = nil
            $0 = nil
        }
    }
    
    // MARK: - OWSAudioPlayerDelegate
    
    public func audioPlaybackState() -> AudioPlaybackState {
        guard let interactionId: Int64 = currentPlayingInteraction.wrappedValue else { return .stopped }
        
        return (playbackInfo.wrappedValue[interactionId]?.state ?? .stopped)
    }
    
    public func setAudioPlaybackState(_ state: AudioPlaybackState) {
        guard let interactionId: Int64 = currentPlayingInteraction.wrappedValue else { return }
        
        let updatedPlaybackInfo: PlaybackInfo? = playbackInfo.wrappedValue[interactionId]?
            .with(state: state)
        
        playbackInfo.mutate { $0[interactionId] = updatedPlaybackInfo }
        updatedPlaybackInfo?.updateCallback(updatedPlaybackInfo, nil)
    }
    
    public func setAudioProgress(_ progress: CGFloat, duration: CGFloat) {
        guard let interactionId: Int64 = currentPlayingInteraction.wrappedValue else { return }
        
        let updatedPlaybackInfo: PlaybackInfo? = playbackInfo.wrappedValue[interactionId]?
            .with(progress: TimeInterval(progress))
        
        playbackInfo.mutate { $0[interactionId] = updatedPlaybackInfo }
        updatedPlaybackInfo?.updateCallback(updatedPlaybackInfo, nil)
    }
    
    public func audioPlayerDidFinishPlaying(_ player: OWSAudioPlayer, successfully: Bool) {
        guard let interactionId: Int64 = currentPlayingInteraction.wrappedValue else { return }
        guard successfully else { return }
        
        let updatedPlaybackInfo: PlaybackInfo? = playbackInfo.wrappedValue[interactionId]?
            .with(
                state: .stopped,
                progress: 0,
                playbackRate: 1
            )
        
        // Safe the changes and send one final update to the UI
        playbackInfo.mutate { $0[interactionId] = updatedPlaybackInfo }
        updatedPlaybackInfo?.updateCallback(updatedPlaybackInfo, nil)
        
        // Clear out the currently playing record
        currentPlayingInteraction.mutate { $0 = nil }
        audioPlayer.mutate {
            // Note: We clear the delegate and explicitly set to nil here as when the OWSAudioPlayer
            // gets deallocated it triggers state changes which cause UI bugs when auto-playing
            $0?.delegate = nil
            $0 = nil
        }
        
        // If the next interaction is another voice message then autoplay it
        guard
            let messageSection: SectionModel = self.interactionData
                .first(where: { $0.model == .messages }),
            let currentIndex: Int = messageSection.elements
                .firstIndex(where: { $0.id == interactionId }),
            currentIndex < (messageSection.elements.count - 1),
            messageSection.elements[currentIndex + 1].cellType == .audio,
            Storage.shared[.shouldAutoPlayConsecutiveAudioMessages] == true
        else { return }
        
        let nextItem: MessageViewModel = messageSection.elements[currentIndex + 1]
        playOrPauseAudio(for: nextItem)
    }
    
    public func showInvalidAudioFileAlert() {
        guard let interactionId: Int64 = currentPlayingInteraction.wrappedValue else { return }
        
        let updatedPlaybackInfo: PlaybackInfo? = playbackInfo.wrappedValue[interactionId]?
            .with(
                state: .stopped,
                progress: 0,
                playbackRate: 1
            )
        
        currentPlayingInteraction.mutate { $0 = nil }
        playbackInfo.mutate { $0[interactionId] = updatedPlaybackInfo }
        updatedPlaybackInfo?.updateCallback(updatedPlaybackInfo, AttachmentError.invalidData)
    }
}
