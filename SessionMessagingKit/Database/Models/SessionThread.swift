// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit
import SessionSnodeKit

public struct SessionThread: Codable, Identifiable, Equatable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "thread" }
    public static let contact = hasOne(Contact.self, using: Contact.threadForeignKey)
    public static let closedGroup = hasOne(ClosedGroup.self, using: ClosedGroup.threadForeignKey)
    public static let openGroup = hasOne(OpenGroup.self, using: OpenGroup.threadForeignKey)
    public static let disappearingMessagesConfiguration = hasOne(
        DisappearingMessagesConfiguration.self,
        using: DisappearingMessagesConfiguration.threadForeignKey
    )
    public static let interactions = hasMany(Interaction.self, using: Interaction.threadForeignKey)
    public static let typingIndicator = hasOne(
        ThreadTypingIndicator.self,
        using: ThreadTypingIndicator.threadForeignKey
    )
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case id
        case variant
        case creationDateTimestamp
        case shouldBeVisible
        @available(*, deprecated, message: "use 'pinnedPriority > 0' instead") case isPinned
        case messageDraft
        case notificationSound
        case mutedUntilTimestamp
        case onlyNotifyForMentions
        case markedAsUnread
        case pinnedPriority
        case isDraft
    }
    
    public enum Variant: Int, Codable, Hashable, DatabaseValueConvertible, CaseIterable {
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
    
    /// A flag indicating whether the thread is pinned
    @available(*, deprecated, message: "use 'pinnedPriority > 0' instead")
    private let isPinned: Bool = false
    
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
    
    // MARK: - Relationships
    
    public var contact: QueryInterfaceRequest<Contact> {
        request(for: SessionThread.contact)
    }
    
    public var closedGroup: QueryInterfaceRequest<ClosedGroup> {
        request(for: SessionThread.closedGroup)
    }
    
    public var openGroup: QueryInterfaceRequest<OpenGroup> {
        request(for: SessionThread.openGroup)
    }
    
    public var disappearingMessagesConfiguration: QueryInterfaceRequest<DisappearingMessagesConfiguration> {
        request(for: SessionThread.disappearingMessagesConfiguration)
    }
    
    public var interactions: QueryInterfaceRequest<Interaction> {
        request(for: SessionThread.interactions)
    }
    
    public var typingIndicator: QueryInterfaceRequest<ThreadTypingIndicator> {
        request(for: SessionThread.typingIndicator)
    }
    
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
        isDraft: Bool? = nil,
        using dependencies: Dependencies
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
    
    public func willInsert(_ db: Database) throws {
        db[.hasSavedThread] = true
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
        }
        
        let creationDateTimestamp: Value<TimeInterval>
        let shouldBeVisible: Value<Bool>
        let pinnedPriority: Value<Int32>
        let isDraft: Value<Bool>
        let disappearingMessagesConfig: Value<DisappearingMessagesConfiguration>
        
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
            disappearingMessagesConfig: Value<DisappearingMessagesConfiguration> = .useLibSession
        ) {
            self.creationDateTimestamp = creationDateTimestamp
            self.shouldBeVisible = shouldBeVisible
            self.pinnedPriority = pinnedPriority
            self.isDraft = isDraft
            self.disappearingMessagesConfig = disappearingMessagesConfig
        }
    }
    
    /// Updates or inserts a `SessionThread` with the specified `id`, `variant` and specified `values`
    ///
    /// **Note:** This method **will** save the newly created/updated `SessionThread` to the database
    @discardableResult static func upsert(
        _ db: Database,
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
                let targetPriority: Int32 = dependencies
                    .mutate(cache: .libSession) { $0.pinnedPriority(db, threadId: id, threadVariant: variant) }
                    .defaulting(to: LibSession.defaultNewThreadPriority)
                
                result = try SessionThread(
                    id: id,
                    variant: variant,
                    creationDateTimestamp: (
                        values.creationDateTimestamp.valueOrNull ??
                        (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000)
                    ),
                    shouldBeVisible: LibSession.shouldBeVisible(priority: targetPriority),
                    pinnedPriority: targetPriority,
                    isDraft: (values.isDraft.valueOrNull == true),
                    using: dependencies
                ).upserted(db)
        }
        
        /// Setup the `DisappearingMessagesConfiguration` as specified
        switch (variant, values.disappearingMessagesConfig) {
            case (.community, _), (_, .useExisting): break      // No need to do anything
            case (_, .setTo(let config)):                       // Save the explicit config
                try config
                    .upserted(db)
                    .clearUnrelatedControlMessages(
                        db,
                        threadVariant: variant,
                        using: dependencies
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
            
            case (_, .useLibSession):                           // Create and save the config from libSession
                let disappearingConfig: DisappearingMessagesConfiguration? = dependencies.mutate(cache: .libSession) { cache in
                    cache.disappearingMessagesConfig(threadId: id, threadVariant: variant)
                }
                
                try disappearingConfig?
                    .upserted(db)
                    .clearUnrelatedControlMessages(
                        db,
                        threadVariant: variant,
                        using: dependencies
                    )
        }
        
        /// Apply any changes if the provided `values` don't match the current or default settings
        var requiredChanges: [ConfigColumnAssignment] = []
        var finalCreationDateTimestamp: TimeInterval = result.creationDateTimestamp
        var finalShouldBeVisible: Bool = result.shouldBeVisible
        var finalPinnedPriority: Int32? = result.pinnedPriority
        var finalIsDraft: Bool? = result.isDraft
        
        /// The `shouldBeVisible` flag is based on `pinnedPriority` so we need to check these two together if they
        /// should both be sourced from `libSession`
        switch (values.pinnedPriority, values.shouldBeVisible) {
            case (.useLibSession, .useLibSession):
                let targetPriority: Int32 = dependencies
                    .mutate(cache: .libSession) { $0.pinnedPriority(db, threadId: id, threadVariant: variant) }
                    .defaulting(to: LibSession.defaultNewThreadPriority)
                let libSessionShouldBeVisible: Bool = LibSession.shouldBeVisible(priority: targetPriority)
                
                if targetPriority != result.pinnedPriority {
                    requiredChanges.append(SessionThread.Columns.pinnedPriority.set(to: targetPriority))
                    finalPinnedPriority = targetPriority
                }
                
                if libSessionShouldBeVisible != result.shouldBeVisible {
                    requiredChanges.append(SessionThread.Columns.shouldBeVisible.set(to: libSessionShouldBeVisible))
                    finalShouldBeVisible = libSessionShouldBeVisible
                }
                
            default: break
        }
        
        /// Otherwise we can just handle the explicit `setTo` cases for these
        if case .setTo(let value) = values.creationDateTimestamp, value != result.creationDateTimestamp {
            requiredChanges.append(SessionThread.Columns.creationDateTimestamp.set(to: value))
            finalCreationDateTimestamp = value
        }
        
        if case .setTo(let value) = values.pinnedPriority, value != result.pinnedPriority {
            requiredChanges.append(SessionThread.Columns.pinnedPriority.set(to: value))
            finalPinnedPriority = value
        }
        
        if case .setTo(let value) = values.shouldBeVisible, value != result.shouldBeVisible {
            requiredChanges.append(SessionThread.Columns.shouldBeVisible.set(to: value))
            finalShouldBeVisible = value
        }
        
        if case .setTo(let value) = values.isDraft, value != result.isDraft {
            requiredChanges.append(SessionThread.Columns.isDraft.set(to: value))
            finalIsDraft = value
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
                    pinnedPriority: finalPinnedPriority,
                    isDraft: finalIsDraft,
                    using: dependencies
                ).upserted(db)
            )
    }
    
    static func canSendReadReceipt(
        _ db: Database,
        threadId: String,
        threadVariant maybeThreadVariant: SessionThread.Variant? = nil,
        isBlocked maybeIsBlocked: Bool? = nil,
        isMessageRequest maybeIsMessageRequest: Bool? = nil,
        using dependencies: Dependencies
    ) throws -> Bool {
        let threadVariant: SessionThread.Variant = try {
            try maybeThreadVariant ??
            SessionThread
                .filter(id: threadId)
                .select(.variant)
                .asRequest(of: SessionThread.Variant.self)
                .fetchOne(db, orThrow: StorageError.objectNotFound)
        }()
        let threadIsBlocked: Bool = try {
            try maybeIsBlocked ??
            (
                threadVariant == .contact &&
                Contact
                    .filter(id: threadId)
                    .select(.isBlocked)
                    .asRequest(of: Bool.self)
                    .fetchOne(db, orThrow: StorageError.objectNotFound)
            )
        }()
        let threadIsMessageRequest: Bool = SessionThread
            .filter(id: threadId)
            .filter(
                SessionThread.isMessageRequest(
                    userSessionId: dependencies[cache: .general].sessionId,
                    includeNonVisible: true
                )
            )
            .isNotEmpty(db)
        
        return (
            !threadIsBlocked &&
            !threadIsMessageRequest
        )
    }
    
    @available(*, unavailable, message: "should not be used until pin re-ordering is built")
    static func refreshPinnedPriorities(_ db: Database, adding threadId: String) throws {
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
        _ db: Database,
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
        _ db: Database,
        type: SessionThread.DeletionType,
        threadIds: [String],
        threadVariant: Variant,
        using dependencies: Dependencies
    ) throws {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let remainingThreadIds: Set<String> = threadIds.asSet().removing(userSessionId.hexString)
        
        switch type {
            case .hideContactConversation:
                _ = try SessionThread
                    .filter(ids: threadIds)
                    .updateAllAndConfig(
                        db,
                        SessionThread.Columns.pinnedPriority.set(to: LibSession.hiddenPriority),
                        SessionThread.Columns.shouldBeVisible.set(to: false),
                        using: dependencies
                    )
                
            case .hideContactConversationAndDeleteContentDirectly:
                // Clear any interactions for the deleted thread
                _ = try Interaction
                    .filter(threadIds.contains(Interaction.Columns.threadId))
                    .deleteAll(db)
                
                // Hide the threads
                _ = try SessionThread
                    .filter(ids: threadIds)
                    .updateAllAndConfig(
                        db,
                        SessionThread.Columns.pinnedPriority.set(to: LibSession.hiddenPriority),
                        SessionThread.Columns.shouldBeVisible.set(to: false),
                        using: dependencies
                    )
            
            case .deleteContactConversationAndMarkHidden:
                _ = try SessionThread
                    .filter(ids: remainingThreadIds)
                    .deleteAll(db)
                
                // We need to custom handle the 'Note to Self' conversation (it should just be
                // hidden locally rather than deleted)
                if threadIds.contains(userSessionId.hexString) {
                    // Clear any interactions for the deleted thread
                    _ = try Interaction
                        .filter(Interaction.Columns.threadId == userSessionId.hexString)
                        .deleteAll(db)
                    
                    _ = try SessionThread
                        .filter(id: userSessionId.hexString)
                        .updateAllAndConfig(
                            db,
                            SessionThread.Columns.pinnedPriority.set(to: LibSession.hiddenPriority),
                            SessionThread.Columns.shouldBeVisible.set(to: false),
                            using: dependencies
                        )
                }
                
                // Update any other threads to be hidden
                try LibSession.hide(db, contactIds: Array(remainingThreadIds), using: dependencies)
                
            case .deleteContactConversationAndContact:
                // Remove the contact from the config
                try LibSession.remove(db, contactIds: Array(remainingThreadIds), using: dependencies)
                
                _ = try SessionThread
                    .filter(ids: remainingThreadIds)
                    .deleteAll(db)
                
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
                    try dependencies[singleton: .openGroupManager].delete(
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
    static func isMessageRequest(
        _ db: Database,
        threadId: String,
        userSessionId: SessionId,
        includeNonVisible: Bool = false
    ) -> Bool {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
        let request: SQLRequest<String> = """
            SELECT \(thread[.id])
            FROM \(SessionThread.self)
            LEFT JOIN \(Contact.self) ON \(contact[.id]) = \(thread[.id])
            LEFT JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])
            WHERE (
                \(thread[.id]) = \(threadId) AND
                \(SessionThread.isMessageRequest(userSessionId: userSessionId, includeNonVisible: includeNonVisible))
            )
        """
        
        return ((try? request.fetchOne(db)) != nil)
    }
    
    static func unreadMessageRequestsCountQuery(userSessionId: SessionId, includeNonVisible: Bool = false) -> SQLRequest<Int> {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
        
        return """
            SELECT COUNT(DISTINCT id) FROM (
                SELECT \(thread[.id]) AS id
                FROM \(SessionThread.self)
                JOIN \(Interaction.self) ON (
                    \(interaction[.threadId]) = \(thread[.id]) AND
                    \(interaction[.wasRead]) = false
                )
                LEFT JOIN \(Contact.self) ON \(contact[.id]) = \(thread[.id])
                LEFT JOIN \(ClosedGroup.self) ON \(closedGroup[.threadId]) = \(thread[.id])
                WHERE (
                    \(SessionThread.isMessageRequest(userSessionId: userSessionId, includeNonVisible: includeNonVisible))
                )
            )
        """
    }
    
    /// This method can be used to filter a thread query to only include messages requests
    ///
    /// **Note:** In order to use this filter you **MUST** have a `joining(required/optional:)` to the
    /// `SessionThread.contact` association or it won't work
    static func isMessageRequest(
        userSessionId: SessionId,
        includeNonVisible: Bool = false
    ) -> SQLExpression {
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let contact: TypedTableAlias<Contact> = TypedTableAlias()
        let closedGroup: TypedTableAlias<ClosedGroup> = TypedTableAlias()
        let shouldBeVisibleSQL: SQL = (includeNonVisible ?
            SQL(stringLiteral: "true") :
            SQL("\(thread[.shouldBeVisible]) = true")
        )
        
        return SQL(
            """
                \(shouldBeVisibleSQL) AND (
                    COALESCE(\(closedGroup[.invited]), false) = true OR (
                        \(SQL("\(thread[.variant]) = \(SessionThread.Variant.contact)")) AND
                        \(SQL("\(thread[.id]) != \(userSessionId.hexString)")) AND
                        IFNULL(\(contact[.isApproved]), false) = false
                    )
                )
            """
        ).sqlExpression
    }
    
    func isNoteToSelf(_ db: Database? = nil, using dependencies: Dependencies) -> Bool {
        return (
            variant == .contact &&
            id == dependencies[cache: .general].sessionId.hexString
        )
    }
    
    func shouldShowNotification(
        _ db: Database,
        for interaction: Interaction,
        isMessageRequest: Bool,
        using dependencies: Dependencies
    ) -> Bool {
        // Ensure that the thread isn't muted and either the thread isn't only notifying for mentions
        // or the user was actually mentioned
        guard
            Date().timeIntervalSince1970 > (self.mutedUntilTimestamp ?? 0) &&
            (
                self.variant == .contact ||
                self.variant == .group ||
                !self.onlyNotifyForMentions ||
                interaction.hasMention
            )
        else { return false }
        
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        
        // No need to notify the user for self-send messages
        guard interaction.authorId != userSessionId.hexString else { return false }
        
        // If the thread is a message request then we only want to notify for the first message
        if (self.variant == .contact || self.variant == .group) && isMessageRequest {
            let numInteractions: Int = {
                switch interaction.serverHash {
                    case .some(let serverHash):
                        return (try? self.interactions
                            .filter(Interaction.Columns.serverHash != serverHash)
                            .fetchCount(db))
                            .defaulting(to: 0)
                    
                    case .none:
                        return (try? self.interactions
                            .filter(Interaction.Columns.timestampMs != interaction.timestampMs)
                            .fetchCount(db))
                            .defaulting(to: 0)
                }
            }()
            
            // We only want to show a notification for the first interaction in the thread
            guard numInteractions == 0 else { return false }
            
            // Need to re-show the message requests section if it had been hidden
            if db[.hasHiddenMessageRequests] {
                db[.hasHiddenMessageRequests] = false
            }
        }
        
        return true
    }
    
    static func displayName(
        threadId: String,
        variant: Variant,
        closedGroupName: String? = nil,
        openGroupName: String? = nil,
        isNoteToSelf: Bool = false,
        profile: Profile? = nil
    ) -> String {
        switch variant {
            case .legacyGroup, .group: return (closedGroupName ?? "groupUnknown".localized())
            case .community: return (openGroupName ?? "communityUnknown".localized())
            case .contact:
                guard !isNoteToSelf else { return "noteToSelf".localized() }
                guard let profile: Profile = profile else {
                    return Profile.truncated(id: threadId, truncating: .middle)
                }
                
                return profile.displayName()
        }
    }
    
    static func getCurrentUserBlindedSessionId(
        _ db: Database? = nil,
        threadId: String,
        threadVariant: Variant,
        blindingPrefix: SessionId.Prefix,
        using dependencies: Dependencies
    ) -> SessionId? {
        guard threadVariant == .community else { return nil }
        guard let db: Database = db else {
            return dependencies[singleton: .storage].read { db in
                getCurrentUserBlindedSessionId(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    blindingPrefix: blindingPrefix,
                    using: dependencies
                )
            }
        }
        
        // Retrieve the relevant open group info
        struct OpenGroupInfo: Decodable, FetchableRecord {
            let publicKey: String
            let server: String
        }
        
        guard
            let userEdKeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db),
            let openGroupInfo: OpenGroupInfo = try? OpenGroup
                .filter(id: threadId)
                .select(.publicKey, .server)
                .asRequest(of: OpenGroupInfo.self)
                .fetchOne(db)
        else { return nil }
        
        // Check the capabilities to ensure the SOGS is blinded (or whether we have no capabilities)
        let capabilities: Set<Capability.Variant> = (try? Capability
            .select(.variant)
            .filter(Capability.Columns.openGroupServer == openGroupInfo.server.lowercased())
            .asRequest(of: Capability.Variant.self)
            .fetchSet(db))
            .defaulting(to: [])
        
        guard capabilities.isEmpty || capabilities.contains(.blind) else { return nil }
        
        switch blindingPrefix {
            case .blinded15:
                return dependencies[singleton: .crypto]
                    .generate(
                        .blinded15KeyPair(
                            serverPublicKey: openGroupInfo.publicKey,
                            ed25519SecretKey: userEdKeyPair.secretKey
                        )
                    )
                    .map { SessionId(.blinded15, publicKey: $0.publicKey) }

            case .blinded25:
                return dependencies[singleton: .crypto]
                    .generate(
                        .blinded25KeyPair(
                            serverPublicKey: openGroupInfo.publicKey,
                            ed25519SecretKey: userEdKeyPair.secretKey
                        )
                    )
                    .map { SessionId(.blinded25, publicKey: $0.publicKey) }

            default: return nil
        }
    }
}
