// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit
import SessionNetworkingKit

public struct SessionThread: Sendable, Codable, Identifiable, Equatable, Hashable, PagableRecord, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible, IdentifiableTableRecord {
    public typealias PagedDataType = SessionThread
    public static var databaseTableName: String { "thread" }
    public static let idColumn: ColumnExpression = Columns.id
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case variant
        case creationDateTimestamp
        case shouldBeVisible
        case messageDraft
        case notificationSound
        case mutedUntilTimestamp
        case onlyNotifyForMentions
        case markedAsUnread
        case pinnedPriority
        case isDraft
    }
    
    public enum Variant: Int, Sendable, Codable, Hashable, DatabaseValueConvertible, CaseIterable {
        case contact
        case legacyGroup
        case community
        case group
    }

    /// Unique identifier for a thread (formerly known as uniqueId)
    ///
    /// This value will depend on the variant:
    /// **contact:** The contact id
    /// **closedGroup:** The closed group public key
    /// **openGroup:** The `\(server.lowercased()).\(room)` value
    public let id: String
    
    /// Enum indicating what type of thread this is
    public let variant: Variant
    
    /// A timestamp indicating when this thread was created
    public let creationDateTimestamp: TimeInterval
    
    /// A flag indicating whether the thread should be visible
    public let shouldBeVisible: Bool
    
    /// The value the user started entering into the input field before they left the conversation screen
    public let messageDraft: String?
    
    /// The sound which should be used when receiving a notification for this thread
    ///
    /// **Note:** If unset this will use the `Preferences.Sound.defaultNotificationSound`
    public let notificationSound: Preferences.Sound?
    
    /// Timestamp (seconds since epoch) for when this thread should stop being muted
    public let mutedUntilTimestamp: TimeInterval?
    
    /// A flag indicating whether the thread should only notify for mentions
    public let onlyNotifyForMentions: Bool
    
    /// A flag indicating whether this thread has been manually marked as unread by the user
    public let markedAsUnread: Bool?
    
    /// A value indicating the priority of this conversation within the pinned conversations
    public let pinnedPriority: Int32?
    
    /// A value indicating whether this conversation is a draft conversation (ie. hasn't sent a message yet and should auto-delete)
    public let isDraft: Bool?
    
    // MARK: - Initialization
    
    public init(
        id: String,
        variant: Variant,
        creationDateTimestamp: TimeInterval,
        shouldBeVisible: Bool = false,
        isPinned: Bool = false,
        messageDraft: String? = nil,
        notificationSound: Preferences.Sound? = nil,
        mutedUntilTimestamp: TimeInterval? = nil,
        onlyNotifyForMentions: Bool = false,
        markedAsUnread: Bool? = false,
        pinnedPriority: Int32? = nil,
        isDraft: Bool? = nil
    ) {
        self.id = id
        self.variant = variant
        self.creationDateTimestamp = creationDateTimestamp
        self.shouldBeVisible = shouldBeVisible
        self.messageDraft = messageDraft
        self.notificationSound = notificationSound
        self.mutedUntilTimestamp = mutedUntilTimestamp
        self.onlyNotifyForMentions = onlyNotifyForMentions
        self.markedAsUnread = markedAsUnread
        self.isDraft = isDraft
        self.pinnedPriority = ((pinnedPriority ?? 0) > 0 ? pinnedPriority :
            (isPinned ? 1 : 0)
        )
    }
    
    // MARK: - Custom Database Interaction
    
    public func aroundInsert(_ db: Database, insert: () throws -> InsertionSuccess) throws {
        _ = try insert()
        
        switch ObservationContext.observingDb {
            case .none: Log.error("[SessionThread] Could not process 'aroundInsert' due to missing observingDb.")
            case .some(let observingDb):
                observingDb.dependencies.setAsync(.hasSavedThread, true)
                observingDb.addConversationEvent(
                    id: id,
                    variant: variant,
                    type: .created
                )
        }
    }
}

// MARK: - Codable

public extension SessionThread {
    init(from decoder: any Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        let pinnedPriority: Int32? = try container.decodeIfPresent(Int32.self, forKey: .pinnedPriority)
        
        self = SessionThread(
            id: try container.decode(String.self, forKey: .id),
            variant: try container.decode(Variant.self, forKey: .variant),
            creationDateTimestamp: try container.decode(TimeInterval.self, forKey: .creationDateTimestamp),
            shouldBeVisible: try container.decode(Bool.self, forKey: .shouldBeVisible),
            isPinned: ((pinnedPriority ?? 0) > 0),
            messageDraft: try container.decodeIfPresent(String.self, forKey: .messageDraft),
            notificationSound: try container.decodeIfPresent(Preferences.Sound.self, forKey: .notificationSound),
            mutedUntilTimestamp: try container.decodeIfPresent(TimeInterval.self, forKey: .mutedUntilTimestamp),
            onlyNotifyForMentions: try container.decode(Bool.self, forKey: .onlyNotifyForMentions),
            markedAsUnread: try container.decodeIfPresent(Bool.self, forKey: .markedAsUnread),
            pinnedPriority: pinnedPriority,
            isDraft: try container.decodeIfPresent(Bool.self, forKey: .isDraft)
        )
    }
}

// MARK: - GRDB Interactions

public extension SessionThread {
    /// This type allows the specification of different `SessionThread` properties to use when creating/updating a thread, by default
    /// it will attempt to use the values set in `libSession` if none are present
    struct TargetValues {
        public enum Value<T> {
            case setTo(T)
            case useLibSession
            
            /// We should generally try to make `libSession` the source of truth for conversation settings (so they sync between
            /// devices) but there are some cases where we don't want to modify a setting (eg. when handling a config change), so
            /// this case can be used for those situations
            case useExisting
            
            /// If the thread doesn't exist then the provided value will be used, if it does exist then the existing value will be used
            case useExistingOrSetTo(T)
            
            var valueOrNull: T? {
                switch self {
                    case .setTo(let value), .useExistingOrSetTo(let value): return value
                    default: return nil
                }
            }
            
            var shouldUseLibSession: Bool {
                switch self {
                    case .useLibSession: return true
                    default: return false
                }
            }
        }
        
        let creationDateTimestamp: Value<TimeInterval>
        let shouldBeVisible: Value<Bool>
        let pinnedPriority: Value<Int32>
        let isDraft: Value<Bool>
        let disappearingMessagesConfig: Value<DisappearingMessagesConfiguration>
        let mutedUntilTimestamp: Value<TimeInterval?>
        let onlyNotifyForMentions: Value<Bool>
        
        // MARK: - Convenience
        
        public static var existingOrDefault: TargetValues {
            return TargetValues(shouldBeVisible: .useLibSession)
        }
        
        // MARK: - Initialization
        
        public init(
            creationDateTimestamp: Value<TimeInterval> = .useExisting,
            shouldBeVisible: Value<Bool>,
            pinnedPriority: Value<Int32> = .useLibSession,
            isDraft: Value<Bool> = .useExisting,
            disappearingMessagesConfig: Value<DisappearingMessagesConfiguration> = .useLibSession,
            mutedUntilTimestamp: Value<TimeInterval?> = .useExisting,
            onlyNotifyForMentions: Value<Bool> = .useExisting
        ) {
            self.creationDateTimestamp = creationDateTimestamp
            self.shouldBeVisible = shouldBeVisible
            self.pinnedPriority = pinnedPriority
            self.isDraft = isDraft
            self.disappearingMessagesConfig = disappearingMessagesConfig
            self.mutedUntilTimestamp = mutedUntilTimestamp
            self.onlyNotifyForMentions = onlyNotifyForMentions
        }
        
        // MARK: - Functions
        
        func resolveLibSessionValues(
            _ db: ObservingDatabase,
            id: ID,
            variant: Variant,
            using dependencies: Dependencies
        ) -> TargetValues {
            guard
                creationDateTimestamp.shouldUseLibSession ||
                shouldBeVisible.shouldUseLibSession ||
                pinnedPriority.shouldUseLibSession ||
                isDraft.shouldUseLibSession ||
                disappearingMessagesConfig.shouldUseLibSession ||
                mutedUntilTimestamp.shouldUseLibSession ||
                onlyNotifyForMentions.shouldUseLibSession
            else { return self }
            
            let openGroupUrlInfo: LibSession.OpenGroupUrlInfo? = (variant != .community ? nil :
                try? LibSession.OpenGroupUrlInfo.fetchOne(db, id: id)
            )
            
            return dependencies.mutate(cache: .libSession) { cache in
                var shouldBeVisible: Value<Bool> = self.shouldBeVisible
                var pinnedPriority: Value<Int32> = self.pinnedPriority
                
                /// The `shouldBeVisible` flag is based on `pinnedPriority` so we need to check these two together if they
                /// should both be sourced from `libSession`
                switch (self.pinnedPriority, self.shouldBeVisible) {
                    case (.useLibSession, .useLibSession):
                        let targetPriority: Int32 = cache.pinnedPriority(
                            threadId: id,
                            threadVariant: variant,
                            openGroupUrlInfo: openGroupUrlInfo
                        )
                        
                        shouldBeVisible = .setTo(LibSession.shouldBeVisible(priority: targetPriority))
                        pinnedPriority = .setTo(targetPriority)
                        
                    default: break
                }
                
                /// Sort out the disappearing message conifg setting
                var disappearingMessagesConfig: Value<DisappearingMessagesConfiguration> = self.disappearingMessagesConfig
                
                if
                    variant != .community,
                    disappearingMessagesConfig.shouldUseLibSession,
                    let config: DisappearingMessagesConfiguration = cache.disappearingMessagesConfig(
                        threadId: id,
                        threadVariant: variant
                    )
                {
                    disappearingMessagesConfig = .setTo(config)
                }
                
                return TargetValues(
                    creationDateTimestamp: self.creationDateTimestamp,
                    shouldBeVisible: shouldBeVisible,
                    pinnedPriority: pinnedPriority,
                    isDraft: self.isDraft,
                    disappearingMessagesConfig: disappearingMessagesConfig,
                    mutedUntilTimestamp: self.mutedUntilTimestamp,
                    onlyNotifyForMentions: self.onlyNotifyForMentions
                )
            }
        }
    }
    
    /// Updates or inserts a `SessionThread` with the specified `id`, `variant` and specified `values`
    ///
    /// **Note:** This method **will** save the newly created/updated `SessionThread` to the database
    @discardableResult static func upsert(
        _ db: ObservingDatabase,
        id: ID,
        variant: Variant,
        values: TargetValues,
        using dependencies: Dependencies
    ) throws -> SessionThread {
        var result: SessionThread
        
        /// If the thread doesn't already exist then create it (with the provided defaults)
        switch try? fetchOne(db, id: id) {
            case .some(let existingThread): result = existingThread
            case .none:
                let targetPriority: Int32 = dependencies.mutate(cache: .libSession) { cache in
                    let openGroupUrlInfo: LibSession.OpenGroupUrlInfo? = (variant != .community ? nil :
                        try? LibSession.OpenGroupUrlInfo.fetchOne(db, id: id)
                    )
                    
                    return cache.pinnedPriority(
                        threadId: id,
                        threadVariant: variant,
                        openGroupUrlInfo: openGroupUrlInfo
                    )
                }
                
                result = try SessionThread(
                    id: id,
                    variant: variant,
                    creationDateTimestamp: (
                        values.creationDateTimestamp.valueOrNull ??
                        (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000)
                    ),
                    shouldBeVisible: LibSession.shouldBeVisible(priority: targetPriority),
                    mutedUntilTimestamp: nil,
                    onlyNotifyForMentions: false,
                    pinnedPriority: targetPriority,
                    isDraft: (values.isDraft.valueOrNull == true)
                ).upserted(db)
        }
        
        /// Apply any changes if the provided `values` don't match the current or default settings
        var requiredChanges: [ConfigColumnAssignment] = []
        var finalCreationDateTimestamp: TimeInterval = result.creationDateTimestamp
        var finalShouldBeVisible: Bool = result.shouldBeVisible
        var finalPinnedPriority: Int32? = result.pinnedPriority
        var finalIsDraft: Bool? = result.isDraft
        var finalMutedUntilTimestamp: TimeInterval? = result.mutedUntilTimestamp
        var finalOnlyNotifyForMentions: Bool = result.onlyNotifyForMentions
        
        /// Resolve any settings which should be sourced from `libSession`
        let resolvedValues: TargetValues = values.resolveLibSessionValues(
            db,
            id: id,
            variant: variant,
            using: dependencies
        )
        
        /// Setup the `DisappearingMessagesConfiguration` as specified
        switch (variant, resolvedValues.disappearingMessagesConfig) {
            case (.community, _), (_, .useExisting): break      // No need to do anything
            case (_, .setTo(let config)):                       // Save the explicit config
                // Don't bother doing anything if the config hasn't changed
                let localConfig: DisappearingMessagesConfiguration = try DisappearingMessagesConfiguration
                    .fetchOne(db, id: id)
                    .defaulting(to: DisappearingMessagesConfiguration.defaultWith(id))
                guard localConfig != config else { break }
                
                try config
                    .upserted(db)
                    .clearUnrelatedControlMessages(
                        db,
                        threadVariant: variant,
                        using: dependencies
                    )
                
                /// Notify of update
                db.addConversationEvent(
                    id: id,
                    variant: variant,
                    type: .updated(.disappearingMessageConfiguration(config))
                )
            
            case (_, .useExistingOrSetTo(let config)):          // Update if we don't have an existing entry
                guard (try? DisappearingMessagesConfiguration.exists(db, id: id)) == false else { break }
                
                try config
                    .upserted(db)
                    .clearUnrelatedControlMessages(
                        db,
                        threadVariant: variant,
                        using: dependencies
                    )
                
                /// Notify of update
                db.addConversationEvent(
                    id: id,
                    variant: variant,
                    type: .updated(.disappearingMessageConfiguration(config))
                )
            
            case (_, .useLibSession): break                     // Shouldn't happen
        }
        
        /// And update any explicit `setTo` cases
        if case .setTo(let value) = values.creationDateTimestamp, value != result.creationDateTimestamp {
            requiredChanges.append(SessionThread.Columns.creationDateTimestamp.set(to: value))
            finalCreationDateTimestamp = value
        }
        
        if case .setTo(let value) = values.shouldBeVisible, value != result.shouldBeVisible {
            requiredChanges.append(SessionThread.Columns.shouldBeVisible.set(to: value))
            finalShouldBeVisible = value
            db.addConversationEvent(
                id: id,
                variant: variant,
                type: .updated(.shouldBeVisible(value))
            )
            
            /// Toggling visibility is the same as "creating"/"deleting" a conversation so send those events as well
            db.addConversationEvent(
                id: id,
                variant: variant,
                type: (value ? .created : .deleted)
            )
            
            /// Need an explicit event for deleting a message request to trigger a home screen update
            if !value && dependencies.mutate(cache: .libSession, { $0.isMessageRequest(threadId: id, threadVariant: variant) }) {
                db.addEvent(.messageRequestDeleted)
            }
        }
        
        if case .setTo(let value) = values.pinnedPriority, value != result.pinnedPriority {
            requiredChanges.append(SessionThread.Columns.pinnedPriority.set(to: value))
            finalPinnedPriority = value
            db.addConversationEvent(
                id: id,
                variant: variant,
                type: .updated(.pinnedPriority(value))
            )
        }
        
        if case .setTo(let value) = values.isDraft, value != result.isDraft {
            requiredChanges.append(SessionThread.Columns.isDraft.set(to: value))
            finalIsDraft = value
        }
        
        if case .setTo(let value) = values.mutedUntilTimestamp, value != result.mutedUntilTimestamp {
            requiredChanges.append(SessionThread.Columns.mutedUntilTimestamp.set(to: value))
            finalMutedUntilTimestamp = value
            db.addConversationEvent(
                id: id,
                variant: variant,
                type: .updated(.mutedUntilTimestamp(value))
            )
        }
        
        if case .setTo(let value) = values.onlyNotifyForMentions, value != result.onlyNotifyForMentions {
            requiredChanges.append(SessionThread.Columns.onlyNotifyForMentions.set(to: value))
            finalOnlyNotifyForMentions = value
            db.addConversationEvent(
                id: id,
                variant: variant,
                type: .updated(.onlyNotifyForMentions(value))
            )
        }
        
        /// If no changes were needed we can just return the existing/default thread
        guard !requiredChanges.isEmpty else { return result }
        
        /// Otherwise save the changes
        try SessionThread
            .filter(id: id)
            .updateAllAndConfig(
                db,
                requiredChanges,
                using: dependencies
            )
        
        /// We need to re-fetch the updated thread as the changes wouldn't have been applied to `result`, it's also possible additional
        /// changes could have happened to the thread during the database operations
        ///
        /// Since we want to avoid returning a nullable `SessionThread` here we need to fallback to a non-null instance, but it should
        /// never be called
        return try fetchOne(db, id: id)
            .defaulting(
                toThrowing: try SessionThread(
                    id: id,
                    variant: variant,
                    creationDateTimestamp: finalCreationDateTimestamp,
                    shouldBeVisible: finalShouldBeVisible,
                    mutedUntilTimestamp: finalMutedUntilTimestamp,
                    onlyNotifyForMentions: finalOnlyNotifyForMentions,
                    pinnedPriority: finalPinnedPriority,
                    isDraft: finalIsDraft
                ).upserted(db)
            )
    }
    
    static func canSendReadReceipt(
        threadId: String,
        threadVariant: SessionThread.Variant,
        using dependencies: Dependencies
    ) throws -> Bool {
        return dependencies.mutate(cache: .libSession) { libSession in
            !libSession.isContactBlocked(contactId: threadId) &&
            !libSession.isMessageRequest(threadId: threadId, threadVariant: threadVariant)
        }
    }
    
    @available(*, unavailable, message: "should not be used until pin re-ordering is built")
    static func refreshPinnedPriorities(_ db: ObservingDatabase, adding threadId: String) throws {
        struct PinnedPriority: TableRecord, ColumnExpressible {
            public typealias Columns = CodingKeys
            public enum CodingKeys: String, CodingKey, ColumnExpression {
                case id
                case rowIndex
            }
        }
        
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let pinnedPriority: TypedTableAlias<PinnedPriority> = TypedTableAlias()
        let rowIndexLiteral: SQL = SQL(stringLiteral: PinnedPriority.Columns.rowIndex.name)
        let pinnedPriorityLiteral: SQL = SQL(stringLiteral: SessionThread.Columns.pinnedPriority.name)
        
        try db.execute(literal: """
            WITH \(PinnedPriority.self) AS (
                SELECT
                    \(thread[.id]),
                    ROW_NUMBER() OVER (
                        ORDER BY \(SQL("\(thread[.id]) != \(threadId)")),
                        \(thread[.pinnedPriority]) ASC
                    ) AS \(rowIndexLiteral)
                FROM \(SessionThread.self)
                WHERE
                    \(thread[.pinnedPriority]) > 0 OR
                    \(SQL("\(thread[.id]) = \(threadId)"))
            )

            UPDATE \(SessionThread.self)
            SET \(pinnedPriorityLiteral) = (
                SELECT \(pinnedPriority[.rowIndex])
                FROM \(PinnedPriority.self)
                WHERE \(pinnedPriority[.id]) = \(thread[.id])
            )
        """)
    }
    
    // stringlint:ignore_contents
    static func interactionInfoWithAttachments(
        threadId: String,
        beforeTimestampMs: Int64? = nil,
        attachmentVariants: [Attachment.Variant] = Attachment.Variant.allCases
    ) throws -> SQLRequest<Interaction.VariantInfo> {
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        let attachment: TypedTableAlias<Attachment> = TypedTableAlias()
        let interactionAttachment: TypedTableAlias<InteractionAttachment> = TypedTableAlias()
        
        return """
            SELECT
                \(interaction[.id]),
                \(interaction[.variant]),
                \(interaction[.serverHash])
            FROM \(interaction)
            JOIN \(interactionAttachment) ON \(interactionAttachment[.interactionId]) = \(interaction[.id])
            JOIN \(attachment) ON (
                \(attachment[.id]) = \(interactionAttachment[.attachmentId]) AND
                \(attachment[.variant]) IN \(attachmentVariants)
            )
            WHERE (
                \(interaction[.threadId]) = \(threadId) AND
                \(interaction[.timestampMs]) < \(beforeTimestampMs ?? Int64.max)
            )
            GROUP BY \(interaction[.id])
        """
    }
}

// MARK: - Deletion

public extension SessionThread {
    enum DeletionType {
        case hideContactConversation
        case hideContactConversationAndDeleteContentDirectly
        case deleteContactConversationAndMarkHidden
        case deleteContactConversationAndContact
        case leaveGroupAsync
        case deleteGroupAndContent
        case deleteCommunityAndContent
    }
    
    static func deleteOrLeave(
        _ db: ObservingDatabase,
        type: SessionThread.DeletionType,
        threadId: String,
        threadVariant: Variant,
        using dependencies: Dependencies
    ) throws {
        try deleteOrLeave(
            db,
            type: type,
            threadIds: [threadId],
            threadVariant: threadVariant,
            using: dependencies
        )
    }
    
    static func deleteOrLeave(
        _ db: ObservingDatabase,
        type: SessionThread.DeletionType,
        threadIds: [String],
        threadVariant: Variant,
        using dependencies: Dependencies
    ) throws {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let remainingThreadIds: Set<String> = threadIds.asSet().removing(userSessionId.hexString)
        
        switch type {
            case .hideContactConversation:
                try SessionThread.updateVisibility(
                    db,
                    threadIds: threadIds,
                    threadVariant: threadVariant,
                    isVisible: false,
                    using: dependencies
                )
                
            case .hideContactConversationAndDeleteContentDirectly:
                // Clear any interactions for the deleted thread
                try Interaction.deleteWhere(
                    db,
                    .filter(threadIds.contains(Interaction.Columns.threadId))
                )
                
                // Hide the threads
                try SessionThread.updateVisibility(
                    db,
                    threadIds: threadIds,
                    threadVariant: threadVariant,
                    isVisible: false,
                    using: dependencies
                )
                
                // Remove desired deduplication records
                try MessageDeduplication.deleteIfNeeded(db, threadIds: threadIds, using: dependencies)
            
            case .deleteContactConversationAndMarkHidden:
                // Clear any interactions for the deleted thread
                try Interaction.deleteWhere(
                    db,
                    .filter(remainingThreadIds.contains(Interaction.Columns.threadId))
                )
                
                try SessionThread
                    .filter(ids: remainingThreadIds)
                    .deleteAll(db)
                
                let messageRequestMap: [String: Bool] = dependencies.mutate(cache: .libSession) { libSession in
                    remainingThreadIds
                        .map { ($0, libSession.isMessageRequest(threadId: $0, threadVariant: threadVariant)) }
                        .reduce(into: [:]) { result, next in result[next.0] = next.1 }
                }
                remainingThreadIds.forEach { id in
                    db.addConversationEvent(
                        id: id,
                        variant: threadVariant,
                        type: .deleted
                    )
                    
                    /// Need an explicit event for deleting a message request to trigger a home screen update
                    if messageRequestMap[id] == true {
                        db.addEvent(.messageRequestDeleted)
                    }
                }
                
                // We need to custom handle the 'Note to Self' conversation (it should just be
                // hidden locally rather than deleted)
                if threadIds.contains(userSessionId.hexString) {
                    // Clear any interactions for the deleted thread
                    try Interaction.deleteWhere(
                        db,
                        .filter(Interaction.Columns.threadId == userSessionId.hexString)
                    )
                    
                    try SessionThread.updateVisibility(
                        db,
                        threadIds: threadIds,
                        threadVariant: threadVariant,
                        isVisible: false,
                        using: dependencies
                    )
                }
                
                // Remove desired deduplication records
                try MessageDeduplication.deleteIfNeeded(db, threadIds: threadIds, using: dependencies)
                
                // Update any other threads to be hidden
                try LibSession.hide(db, contactIds: Array(remainingThreadIds), using: dependencies)
                
            case .deleteContactConversationAndContact:
                // Remove the contact from the config (also need to clear the nickname since that's
                // custom data for this contact)
                try LibSession.remove(db, contactIds: Array(remainingThreadIds), using: dependencies)
                
                try Profile
                    .filter(ids: remainingThreadIds)
                    .updateAll(db, Profile.Columns.nickname.set(to: nil))
                
                try Contact
                    .filter(ids: remainingThreadIds)
                    .deleteAll(db)
                
                try Interaction.deleteWhere(
                    db,
                    .filter(remainingThreadIds.contains(Interaction.Columns.threadId))
                )
                
                try SessionThread
                    .filter(ids: remainingThreadIds)
                    .deleteAll(db)
                
                let messageRequestMap: [String: Bool] = dependencies.mutate(cache: .libSession) { libSession in
                    remainingThreadIds
                        .map { ($0, libSession.isMessageRequest(threadId: $0, threadVariant: threadVariant)) }
                        .reduce(into: [:]) { result, next in result[next.0] = next.1 }
                }
                remainingThreadIds.forEach { id in
                    db.addConversationEvent(
                        id: id,
                        variant: threadVariant,
                        type: .deleted
                    )
                    
                    /// Need an explicit event for deleting a message request to trigger a home screen update
                    if messageRequestMap[id] == true {
                        db.addEvent(.messageRequestDeleted)
                    }
                }
                
                // Remove desired deduplication records
                try MessageDeduplication.deleteIfNeeded(db, threadIds: threadIds, using: dependencies)
                
            case .leaveGroupAsync:
                try threadIds.forEach { threadId in
                    try MessageSender.leave(db, threadId: threadId, threadVariant: threadVariant, using: dependencies)
                }
                
            case .deleteGroupAndContent:
                try ClosedGroup.removeData(
                    db,
                    threadIds: threadIds,
                    dataToRemove: .allData,
                    using: dependencies
                )
            
            case .deleteCommunityAndContent:
                try threadIds.forEach { threadId in
                    try dependencies[singleton: .communityManager].delete(
                        db,
                        openGroupId: threadId,
                        skipLibSessionUpdate: false
                    )
                }
        }
    }
}

// MARK: - Convenience

public extension SessionThread {
    func with(
        shouldBeVisible: Update<Bool> = .useExisting,
        messageDraft: Update<String?> = .useExisting,
        mutedUntilTimestamp: Update<TimeInterval?> = .useExisting,
        onlyNotifyForMentions: Update<Bool> = .useExisting,
        markedAsUnread: Update<Bool?> = .useExisting,
        pinnedPriority: Update<Int32?> = .useExisting
    ) -> SessionThread {
        return SessionThread(
            id: id,
            variant: variant,
            creationDateTimestamp: creationDateTimestamp,
            shouldBeVisible: shouldBeVisible.or(self.shouldBeVisible),
            messageDraft: messageDraft.or(self.messageDraft),
            mutedUntilTimestamp: mutedUntilTimestamp.or(self.mutedUntilTimestamp),
            onlyNotifyForMentions: onlyNotifyForMentions.or(self.onlyNotifyForMentions),
            markedAsUnread: markedAsUnread.or(self.markedAsUnread),
            pinnedPriority: pinnedPriority.or(self.pinnedPriority),
            isDraft: isDraft
        )
    }
    
    static func updateVisibility(
        _ db: ObservingDatabase,
        threadId: String,
        threadVariant: SessionThread.Variant,
        isVisible: Bool,
        customPriority: Int32? = nil,
        additionalChanges: [ConfigColumnAssignment] = [],
        using dependencies: Dependencies
    ) throws {
        try updateVisibility(
            db,
            threadIds: [threadId],
            threadVariant: threadVariant,
            isVisible: isVisible,
            customPriority: customPriority,
            additionalChanges: additionalChanges,
            using: dependencies
        )
    }
    
    static func updateVisibility(
        _ db: ObservingDatabase,
        threadIds: [String],
        threadVariant: SessionThread.Variant,
        isVisible: Bool,
        customPriority: Int32? = nil,
        additionalChanges: [ConfigColumnAssignment] = [],
        using dependencies: Dependencies
    ) throws {
        struct ThreadInfo: Decodable, FetchableRecord {
            var id: String
            var shouldBeVisible: Bool
            var pinnedPriority: Int32
        }
        
        let targetPriority: Int32
        
        switch (customPriority, isVisible) {
            case (.some(let priority), _): targetPriority = priority
            case (.none, true): targetPriority = LibSession.visiblePriority
            case (.none, false): targetPriority = LibSession.hiddenPriority
        }
        
        let currentInfo: [String: ThreadInfo] = try SessionThread
            .select(.id, .shouldBeVisible, .pinnedPriority)
            .filter(ids: threadIds)
            .asRequest(of: ThreadInfo.self)
            .fetchAll(db)
            .reduce(into: [:]) { result, next in
                result[next.id] = next
            }
        
        _ = try SessionThread
            .filter(ids: threadIds)
            .updateAllAndConfig(
                db,
                [
                    SessionThread.Columns.pinnedPriority.set(to: targetPriority),
                    SessionThread.Columns.shouldBeVisible.set(to: isVisible)
                ].appending(contentsOf: additionalChanges),
                using: dependencies
            )
        
        /// Emit events for any changes
        threadIds.forEach { id in
            if currentInfo[id]?.shouldBeVisible != isVisible {
                db.addConversationEvent(
                    id: id,
                    variant: threadVariant,
                    type: .updated(.shouldBeVisible(isVisible))
                )
                
                /// Toggling visibility is the same as "creating"/"deleting" a conversation
                db.addConversationEvent(
                    id: id,
                    variant: threadVariant,
                    type: (isVisible ? .created : .deleted)
                )
            }
            
            if currentInfo[id]?.pinnedPriority != targetPriority {
                db.addConversationEvent(
                    id: id,
                    variant: threadVariant,
                    type: .updated(.pinnedPriority(targetPriority))
                )
            }
        }
    }
    
    static func unreadMessageRequestsQuery(messageRequestThreadIds: Set<String>) -> SQLRequest<Int> {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        
        return """
            SELECT DISTINCT \(thread[.id])
            FROM \(SessionThread.self)
            JOIN \(Interaction.self) ON (
                \(interaction[.threadId]) = \(thread[.id]) AND
                \(interaction[.wasRead]) = false AND
                \(interaction[.variant]) IN \(Interaction.Variant.variantsToIncrementUnreadCount)
            )
            WHERE \(thread[.id]) IN \(messageRequestThreadIds)
        """
    }
    
    func isNoteToSelf(using dependencies: Dependencies) -> Bool {
        return (
            variant == .contact &&
            id == dependencies[cache: .general].sessionId.hexString
        )
    }
    
    static func displayName(
        threadId: String,
        variant: Variant,
        groupName: String?,
        communityName: String?,
        isNoteToSelf: Bool,
        ignoreNickname: Bool,
        profile: Profile?
    ) -> String {
        switch variant {
            case .legacyGroup, .group: return (groupName ?? "groupUnknown".localized())
            case .community: return (communityName ?? "communityUnknown".localized())
            case .contact:
                guard !isNoteToSelf else { return "noteToSelf".localized() }
                guard let profile: Profile = profile else { return threadId.truncated() }
                
                return profile.displayName(ignoreNickname: ignoreNickname)
        }
    }
    
    static func getCurrentUserBlindedSessionId(
        threadId: String,
        threadVariant: Variant,
        blindingPrefix: SessionId.Prefix,
        openGroupCapabilityInfo: LibSession.OpenGroupCapabilityInfo?,
        using dependencies: Dependencies
    ) -> SessionId? {
        guard
            threadVariant == .community,
            let openGroupCapabilityInfo: LibSession.OpenGroupCapabilityInfo = openGroupCapabilityInfo
        else { return nil }
        
        return getCurrentUserBlindedSessionId(
            publicKey: openGroupCapabilityInfo.publicKey,
            blindingPrefix: blindingPrefix,
            capabilities: openGroupCapabilityInfo.capabilities,
            using: dependencies
        )
    }
    
    static func getCurrentUserBlindedSessionId(
        publicKey: String,
        blindingPrefix: SessionId.Prefix,
        capabilities: Set<Capability.Variant>,
        using dependencies: Dependencies
    ) -> SessionId? {
        /// Check the capabilities to ensure the SOGS is blinded (or whether we have no capabilities)
        guard capabilities.isEmpty || capabilities.contains(.blind) else { return nil }
        
        switch blindingPrefix {
            case .blinded15:
                return dependencies[singleton: .crypto]
                    .generate(
                        .blinded15KeyPair(
                            serverPublicKey: publicKey,
                            ed25519SecretKey: dependencies[cache: .general].ed25519SecretKey
                        )
                    )
                    .map { SessionId(.blinded15, publicKey: $0.publicKey) }

            case .blinded25:
                return dependencies[singleton: .crypto]
                    .generate(
                        .blinded25KeyPair(
                            serverPublicKey: publicKey,
                            ed25519SecretKey: dependencies[cache: .general].ed25519SecretKey
                        )
                    )
                    .map { SessionId(.blinded25, publicKey: $0.publicKey) }

            default: return nil
        }
    }
}
