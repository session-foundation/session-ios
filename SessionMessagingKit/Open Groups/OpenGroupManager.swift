// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionNetworkingKit

// MARK: - Singleton

public extension Singleton {
    static let openGroupManager: SingletonConfig<OpenGroupManagerType> = Dependencies.create(
        identifier: "openGroupManager",
        createInstance: { dependencies, _ in OpenGroupManager(using: dependencies) }
    )
}

// MARK: - Log.Category

public extension Log.Category {
    static let openGroup: Log.Category = .create("OpenGroup", defaultLevel: .info)
}

// MARK: - OpenGroupManager

public actor OpenGroupManager: OpenGroupManagerType {
    public typealias DefaultRoomInfo = (room: Network.SOGS.Room, openGroup: OpenGroup)
    
    nonisolated public let syncState: OpenGroupManagerSyncState
    public let dependencies: Dependencies
    
    nonisolated private let _defaultRooms: CurrentValueAsyncStream<[DefaultRoomInfo]> = CurrentValueAsyncStream([])
    private var _lastSuccessfulCommunityPollTimestamp: TimeInterval?
    
    public private(set) var pendingChanges: [OpenGroupManager.PendingChange] = []
    nonisolated public var defaultRooms: AsyncStream<[DefaultRoomInfo]> {
        return AsyncStream { continuation in
            let bridgingTask = Task {
                for await element in _defaultRooms.stream {
                    /// If we don't have any default rooms in memory then we haven't fetched this launch so schedule
                    /// the `RetrieveDefaultOpenGroupRoomsJob` if one isn't already running
                    if element.isEmpty {
                        let dependencies: Dependencies = await self.dependencies
                        RetrieveDefaultOpenGroupRoomsJob.run(using: dependencies)
                    }
                    
                    continuation.yield(element)
                }
                
                continuation.finish()
            }
            
            continuation.onTermination = { @Sendable _ in
                bridgingTask.cancel()
            }
        }
    }
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.syncState = OpenGroupManagerSyncState(using: dependencies)
    }

    // MARK: - Adding & Removing
    
    nonisolated public func hasExistingOpenGroup(
        _ db: ObservingDatabase,
        roomToken: String,
        server: String,
        publicKey: String
    ) -> Bool {
        guard let serverUrl: URL = URL(string: server.lowercased()) else { return false }
        
        let serverPort: String = OpenGroupManager.port(for: server, serverUrl: serverUrl)
        let serverHost: String = serverUrl.host
            .defaulting(
                to: server
                    .lowercased()
                    .replacingOccurrences(of: serverPort, with: "")
            )
        let defaultServerHost: String = Network.SOGS.defaultServer
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
        var serverOptions: Set<String> = Set([
            server.lowercased(),
            "\(serverHost)\(serverPort)",
            "http://\(serverHost)\(serverPort)",
            "https://\(serverHost)\(serverPort)"
        ])
        
        // If the server is run by Session then include all configurations in case one of the alternate configurations
        // was used
        if OpenGroupManager.isSessionRunOpenGroup(server: server) {
            serverOptions.insert(defaultServerHost)
            serverOptions.insert("http://\(defaultServerHost)")
            serverOptions.insert("https://\(defaultServerHost)")
            serverOptions.insert(Network.SOGS.legacyDefaultServerIP)
            serverOptions.insert("http://\(Network.SOGS.legacyDefaultServerIP)")
            serverOptions.insert("https://\(Network.SOGS.legacyDefaultServerIP)")
        }
        
        // First check if there is no poller for the specified server
        if Set(syncState.dependencies[singleton: .communityPollerManager].syncState.serversBeingPolled).intersection(serverOptions).isEmpty {
            return false
        }
        
        // Then check if there is an existing open group thread
        let hasExistingThread: Bool = serverOptions.contains(where: { serverName in
            (try? SessionThread
                .exists(
                    db,
                    id: OpenGroup.idFor(roomToken: roomToken, server: serverName)
                ))
                .defaulting(to: false)
        })
                                                                  
        return hasExistingThread
    }
    
    nonisolated public func add(
        _ db: ObservingDatabase,
        roomToken: String,
        server: String,
        publicKey: String,
        forceVisible: Bool
    ) -> Bool {
        // If we are currently polling for this server and already have a TSGroupThread for this room the do nothing
        if hasExistingOpenGroup(db, roomToken: roomToken, server: server, publicKey: publicKey) {
            Log.info(.openGroup, "Ignoring join open group attempt (already joined)")
            return false
        }
        
        // Store the open group information
        let targetServer: String = {
            guard OpenGroupManager.isSessionRunOpenGroup(server: server) else {
                return server.lowercased()
            }
            
            return Network.SOGS.defaultServer
        }()
        let threadId: String = OpenGroup.idFor(roomToken: roomToken, server: targetServer)
        
        // Optionally try to insert a new version of the OpenGroup (it will fail if there is already an
        // inactive one but that won't matter as we then activate it)
        _ = try? SessionThread.upsert(
            db,
            id: threadId,
            variant: .community,
            values: SessionThread.TargetValues(
                /// When adding an open group via config handling then we want to force it to be visible (if it did come via config
                /// handling then we want to wait until it actually has messages before making it visible)
                shouldBeVisible: (forceVisible ? .setTo(true) :  .useExisting)
            ),
            using: syncState.dependencies
        )
        
        if (try? OpenGroup.exists(db, id: threadId)) == false {
            try? OpenGroup
                .fetchOrCreate(db, server: targetServer, roomToken: roomToken, publicKey: publicKey)
                .upsert(db)
        }
        
        // Set the group to active and reset the sequenceNumber (handle groups which have
        // been deactivated)
        if (try? OpenGroup.select(.isActive).filter(id: threadId).asRequest(of: Bool.self).fetchOne(db)) != true {
            _ = try? OpenGroup
                .filter(id: OpenGroup.idFor(roomToken: roomToken, server: targetServer))
                .updateAllAndConfig(
                    db,
                    OpenGroup.Columns.isActive.set(to: true),
                    OpenGroup.Columns.sequenceNumber.set(to: 0),
                    using: syncState.dependencies
                )
        }
        
        return true
    }
    
    nonisolated public func performInitialRequestsAfterAdd(
        queue: DispatchQueue,
        successfullyAddedGroup: Bool,
        roomToken: String,
        server: String,
        publicKey: String
    ) -> AnyPublisher<Void, Error> {
        // Only bother performing the initial request if the network isn't suspended
        guard
            successfullyAddedGroup,
            !syncState.dependencies[singleton: .storage].isSuspended,
            !syncState.dependencies[singleton: .network].syncState.isSuspended
        else {
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        // Store the open group information
        let targetServer: String = {
            guard OpenGroupManager.isSessionRunOpenGroup(server: server) else {
                return server.lowercased()
            }
            
            return Network.SOGS.defaultServer
        }()
        
        return Result {
            try Network.SOGS
                .preparedCapabilitiesAndRoom(
                    roomToken: roomToken,
                    authMethod: Authentication.community(
                        info: LibSession.OpenGroupCapabilityInfo(
                            roomToken: roomToken,
                            server: server,
                            publicKey: publicKey,
                            capabilities: []    /// We won't have `capabilities` before the first request so just hard code
                        )
                    ),
                    using: syncState.dependencies
                )
            }
            .publisher
            .flatMap { [dependencies = syncState.dependencies] in $0.send(using: dependencies) }
            .flatMapStorageWritePublisher(using: syncState.dependencies) { [weak self, dependencies = syncState.dependencies] (db: ObservingDatabase, response: (info: ResponseInfoType, value: Network.SOGS.CapabilitiesAndRoomResponse)) -> Void in
                guard let self = self else { throw StorageError.objectNotSaved }
                
                // Add the new open group to libSession
                try LibSession.add(
                    db,
                    server: server,
                    rootToken: roomToken,
                    publicKey: publicKey,
                    using: dependencies
                )
                
                // Store the capabilities first
                handleCapabilities(
                    db,
                    capabilities: response.value.capabilities.data,
                    on: targetServer
                )
                
                // Then the room
                try handlePollInfo(
                    db,
                    pollInfo: Network.SOGS.RoomPollInfo(room: response.value.room.data),
                    publicKey: publicKey,
                    for: roomToken,
                    on: targetServer
                )
            }
            .handleEvents(
                receiveCompletion: { [communityPollerManager = syncState.dependencies[singleton: .communityPollerManager]] result in
                    switch result {
                        case .finished:
                            /// (Re)start the poller if needed (want to force it to poll immediately in the next run loop to avoid
                            /// a big delay before the next poll)
                            Task { [communityPollerManager] in
                                let poller = await communityPollerManager.getOrCreatePoller(for: server.lowercased())
                                await poller.stop()
                                await poller.startIfNeeded()
                            }
                            
                        case .failure(let error): Log.error(.openGroup, "Failed to join open group with error: \(error).")
                    }
                }
            )
            .eraseToAnyPublisher()
    }

    nonisolated public func delete(
        _ db: ObservingDatabase,
        openGroupId: String,
        skipLibSessionUpdate: Bool
    ) throws {
        let server: String? = try? OpenGroup
            .select(.server)
            .filter(id: openGroupId)
            .asRequest(of: String.self)
            .fetchOne(db)
        let roomToken: String? = try? OpenGroup
            .select(.roomToken)
            .filter(id: openGroupId)
            .asRequest(of: String.self)
            .fetchOne(db)
        
        // Stop the poller if needed
        //
        // Note: The default room promise creates an OpenGroup with an empty `roomToken` value,
        // we don't want to start a poller for this as the user hasn't actually joined a room
        let numActiveRooms: Int = (try? OpenGroup
            .filter(OpenGroup.Columns.server == server?.lowercased())
            .filter(OpenGroup.Columns.roomToken != "")
            .filter(OpenGroup.Columns.isActive)
            .fetchCount(db))
            .defaulting(to: 1)
        
        if numActiveRooms == 1, let server: String = server?.lowercased() {
            Task { [manager = syncState.dependencies[singleton: .communityPollerManager]] in
                await manager.stopAndRemovePoller(for: server)
            }
        }
        
        // Remove all the data (everything should cascade delete)
        _ = try? Interaction.deleteWhere(db, .filter(Interaction.Columns.threadId == openGroupId))
        _ = try? SessionThread
            .filter(id: openGroupId)
            .deleteAll(db)
        
        db.addConversationEvent(id: openGroupId, type: .deleted)
        
        // Remove any dedupe records (we will want to reprocess all OpenGroup messages if they get re-added)
        try MessageDeduplication.deleteIfNeeded(db, threadIds: [openGroupId], using: syncState.dependencies)
        
        // Remove the open group (no foreign key to the thread so it won't auto-delete)
        if server?.lowercased() != Network.SOGS.defaultServer.lowercased() {
            _ = try? OpenGroup
                .filter(id: openGroupId)
                .deleteAll(db)
        }
        else {
            // If it's a session-run room then just set it to inactive
            _ = try? OpenGroup
                .filter(id: openGroupId)
                .updateAllAndConfig(
                    db,
                    OpenGroup.Columns.isActive.set(to: false),
                    using: syncState.dependencies
                )
        }
        
        if !skipLibSessionUpdate, let server: String = server, let roomToken: String = roomToken {
            try LibSession.remove(db, server: server, roomToken: roomToken, using: syncState.dependencies)
        }
    }
    
    // MARK: - Default Rooms
    
    public func setDefaultRoomInfo(_ info: [DefaultRoomInfo]) async {
        await _defaultRooms.send(info)
    }
    
    // MARK: - Polling
    
    public func getLastSuccessfulCommunityPollTimestamp() -> TimeInterval {
        if let storedTime: TimeInterval = _lastSuccessfulCommunityPollTimestamp {
            return storedTime
        }
        
        guard let lastPoll: Date = dependencies[defaults: .standard, key: .lastOpen] else {
            return 0
        }
        
        _lastSuccessfulCommunityPollTimestamp = lastPoll.timeIntervalSince1970
        return lastPoll.timeIntervalSince1970
    }
    
    public func setLastSuccessfulCommunityPollTimestamp(_ timestamp: TimeInterval) {
        dependencies[defaults: .standard, key: .lastOpen] = Date(timeIntervalSince1970: timestamp)
        _lastSuccessfulCommunityPollTimestamp = timestamp
    }
    
    // MARK: - Response Processing
    
    nonisolated public func handleCapabilities(
        _ db: ObservingDatabase,
        capabilities: Network.SOGS.CapabilitiesResponse,
        on server: String
    ) {
        // Remove old capabilities first
        _ = try? Capability
            .filter(Capability.Columns.openGroupServer == server.lowercased())
            .deleteAll(db)
        
        // Then insert the new capabilities (both present and missing)
        capabilities.capabilities.forEach { capability in
            try? Capability(
                openGroupServer: server.lowercased(),
                variant: Capability.Variant(from: capability),
                isMissing: false
            )
            .upsert(db)
        }
        capabilities.missing?.forEach { capability in
            try? Capability(
                openGroupServer: server.lowercased(),
                variant: Capability.Variant(from: capability),
                isMissing: true
            )
            .upsert(db)
        }
    }
    
    nonisolated public func handlePollInfo(
        _ db: ObservingDatabase,
        pollInfo: Network.SOGS.RoomPollInfo,
        publicKey maybePublicKey: String?,
        for roomToken: String,
        on server: String
    ) throws {
        // Create the open group model and get or create the thread
        let threadId: String = OpenGroup.idFor(roomToken: roomToken, server: server)
        
        guard let openGroup: OpenGroup = try OpenGroup.fetchOne(db, id: threadId) else { return }
        
        // Only update the database columns which have changed (this is to prevent the UI from triggering
        // updates due to changing database columns to the existing value)
        let hasDetails: Bool = (pollInfo.details != nil)
        let permissions: OpenGroup.Permissions = OpenGroup.Permissions(roomInfo: pollInfo)
        let changes: [ConfigColumnAssignment] = []
            .appending(openGroup.publicKey == maybePublicKey ? nil :
                maybePublicKey.map { OpenGroup.Columns.publicKey.set(to: $0) }
            )
            .appending(openGroup.userCount == pollInfo.activeUsers ? nil :
                OpenGroup.Columns.userCount.set(to: pollInfo.activeUsers)
            )
            .appending(openGroup.permissions == permissions ? nil :
                OpenGroup.Columns.permissions.set(to: permissions)
            )
            .appending(!hasDetails || openGroup.name == pollInfo.details?.name ? nil :
                OpenGroup.Columns.name.set(to: pollInfo.details?.name)
            )
            .appending(!hasDetails || openGroup.roomDescription == pollInfo.details?.roomDescription ? nil :
                OpenGroup.Columns.roomDescription.set(to: pollInfo.details?.roomDescription)
            )
            .appending(!hasDetails || openGroup.imageId == pollInfo.details?.imageId ? nil :
                OpenGroup.Columns.imageId.set(to: pollInfo.details?.imageId)
            )
            .appending(!hasDetails || openGroup.infoUpdates == pollInfo.details?.infoUpdates ? nil :
                OpenGroup.Columns.infoUpdates.set(to: pollInfo.details?.infoUpdates)
            )
        
        try OpenGroup
            .filter(id: openGroup.id)
            .updateAllAndConfig(db, changes, using: syncState.dependencies)
        
        // Update the admin/moderator group members
        if let roomDetails: Network.SOGS.Room = pollInfo.details {
            _ = try? GroupMember
                .filter(GroupMember.Columns.groupId == threadId)
                .deleteAll(db)
            
            try roomDetails.admins.forEach { adminId in
                try GroupMember(
                    groupId: threadId,
                    profileId: adminId,
                    role: .admin,
                    roleStatus: .accepted,  // Community members don't have role statuses
                    isHidden: false
                ).upsert(db)
            }
            
            try roomDetails.hiddenAdmins
                .defaulting(to: [])
                .forEach { adminId in
                    try GroupMember(
                        groupId: threadId,
                        profileId: adminId,
                        role: .admin,
                        roleStatus: .accepted,  // Community members don't have role statuses
                        isHidden: true
                    ).upsert(db)
                }
            
            try roomDetails.moderators.forEach { moderatorId in
                try GroupMember(
                    groupId: threadId,
                    profileId: moderatorId,
                    role: .moderator,
                    roleStatus: .accepted,      // Community members don't have role statuses
                    isHidden: false
                ).upsert(db)
            }
            
            try roomDetails.hiddenModerators
                .defaulting(to: [])
                .forEach { moderatorId in
                    try GroupMember(
                        groupId: threadId,
                        profileId: moderatorId,
                        role: .moderator,
                        roleStatus: .accepted,  // Community members don't have role statuses
                        isHidden: true
                    ).upsert(db)
                }
        }
        
        /// Schedule the room image download (if we don't have one or it's been updated)
        if
            let imageId: String = (pollInfo.details?.imageId ?? openGroup.imageId),
            (
                openGroup.displayPictureOriginalUrl == nil ||
                openGroup.imageId != imageId
            )
        {
            syncState.dependencies[singleton: .jobRunner].add(
                db,
                job: Job(
                    variant: .displayPictureDownload,
                    shouldBeUnique: true,
                    details: DisplayPictureDownloadJob.Details(
                        target: .community(
                            imageId: imageId,
                            roomToken: openGroup.roomToken,
                            server: openGroup.server
                        ),
                        timestamp: (syncState.dependencies.networkOffsetTimestampMs() / 1000)
                    )
                ),
                canStartJob: true
            )
        }
        
        /// Emit events
        if hasDetails {
            if openGroup.name != pollInfo.details?.name {
                db.addConversationEvent(
                    id: openGroup.id,
                    type: .updated(.displayName(pollInfo.details?.name ?? openGroup.name))
                )
            }
            
            if openGroup.roomDescription == pollInfo.details?.roomDescription {
                db.addConversationEvent(
                    id: openGroup.id,
                    type: .updated(.description(pollInfo.details?.roomDescription))
                )
            }
            
            if pollInfo.details?.imageId == nil {
                db.addConversationEvent(id: openGroup.id, type: .updated(.displayPictureUrl(nil)))
            }
        }
    }
    
    nonisolated public func handleMessages(
        _ db: ObservingDatabase,
        messages: [Network.SOGS.Message],
        for roomToken: String,
        on server: String
    ) -> [MessageReceiver.InsertedInteractionInfo?] {
        guard let openGroup: OpenGroup = try? OpenGroup.fetchOne(db, id: OpenGroup.idFor(roomToken: roomToken, server: server)) else {
            Log.error(.openGroup, "Couldn't handle open group messages due to missing group.")
            return []
        }
        
        // Sorting the messages by server ID before importing them fixes an issue where messages
        // that quote older messages can't find those older messages
        let sortedMessages: [Network.SOGS.Message] = messages
            .filter { $0.deleted != true }
            .sorted { lhs, rhs in lhs.id < rhs.id }
        var messageServerInfoToRemove: [(id: Int64, seqNo: Int64)] = messages
            .filter { $0.deleted == true }
            .map { ($0.id, $0.seqNo) }
        var largestValidSeqNo: Int64 = openGroup.sequenceNumber
        var insertedInteractionInfo: [MessageReceiver.InsertedInteractionInfo?] = []
        
        // Process the messages
        sortedMessages.forEach { message in
            if message.base64EncodedData == nil && message.reactions == nil {
                messageServerInfoToRemove.append((message.id, message.seqNo))
                return
            }
            
            // Handle messages
            if
                let base64EncodedString: String = message.base64EncodedData,
                let data = Data(base64Encoded: base64EncodedString),
                let sender: String = message.sender
            {
                do {
                    let processedMessage: ProcessedMessage = try MessageReceiver.parse(
                        data: data,
                        origin: .community(
                            openGroupId: openGroup.id,
                            sender: sender,
                            timestamp: message.posted,
                            messageServerId: message.id,
                            whisper: message.whisper,
                            whisperMods: message.whisperMods,
                            whisperTo: message.whisperTo
                        ),
                        using: syncState.dependencies
                    )
                    try MessageDeduplication.insert(
                        db,
                        processedMessage: processedMessage,
                        ignoreDedupeFiles: false,
                        using: syncState.dependencies
                    )
                    
                    switch processedMessage {
                        case .config, .invalid: break
                        case .standard(_, _, _, let messageInfo, _):
                            insertedInteractionInfo.append(
                                try MessageReceiver.handle(
                                    db,
                                    threadId: openGroup.id,
                                    threadVariant: .community,
                                    message: messageInfo.message,
                                    serverExpirationTimestamp: messageInfo.serverExpirationTimestamp,
                                    associatedWithProto: try SNProtoContent.parseData(messageInfo.serializedProtoData),
                                    suppressNotifications: false,
                                    using: syncState.dependencies
                                )
                            )
                            largestValidSeqNo = max(largestValidSeqNo, message.seqNo)
                    }
                }
                catch {
                    switch error {
                        // Ignore duplicate & selfSend message errors (and don't bother logging
                        // them as there will be a lot since we each service node duplicates messages)
                        case DatabaseError.SQLITE_CONSTRAINT_UNIQUE,
                            DatabaseError.SQLITE_CONSTRAINT,    // Sometimes thrown for UNIQUE
                            MessageReceiverError.duplicateMessage,
                            MessageReceiverError.selfSend:
                            break
                        
                        default: Log.error(.openGroup, "Couldn't receive open group message due to error: \(error).")
                    }
                }
            }
            
            // Handle reactions
            if message.reactions != nil {
                do {
                    let reactions: [Reaction] = Message.processRawReceivedReactions(
                        db,
                        openGroupId: openGroup.id,
                        message: message,
                        associatedPendingChanges: syncState.pendingChanges
                            .filter {
                                guard $0.server == server && $0.room == roomToken && $0.changeType == .reaction else {
                                    return false
                                }
                                
                                if case .reaction(let messageId, _, _) = $0.metadata {
                                    return messageId == message.id
                                }
                                return false
                            },
                        using: syncState.dependencies
                    )
                    
                    try MessageReceiver.handleOpenGroupReactions(
                        db,
                        threadId: openGroup.threadId,
                        openGroupMessageServerId: message.id,
                        openGroupReactions: reactions
                    )
                    largestValidSeqNo = max(largestValidSeqNo, message.seqNo)
                }
                catch {
                    Log.error(.openGroup, "Couldn't handle open group reactions due to error: \(error).")
                }
            }
        }

        // Handle any deletions that are needed
        if !messageServerInfoToRemove.isEmpty {
            let messageServerIdsToRemove: [Int64] = messageServerInfoToRemove.map { $0.id }
            _ = try? Interaction.deleteWhere(
                db,
                .filter(Interaction.Columns.threadId == openGroup.threadId),
                .filter(messageServerIdsToRemove.contains(Interaction.Columns.openGroupServerMessageId))
            )
            
            // Update the seqNo for deletions
            largestValidSeqNo = max(largestValidSeqNo, (messageServerInfoToRemove.map({ $0.seqNo }).max() ?? 0))
        }
        
        // Now that we've finished processing all valid message changes we can update the `sequenceNumber` to
        // the `largestValidSeqNo` value
        _ = try? OpenGroup
            .filter(id: openGroup.id)
            .updateAll(db, OpenGroup.Columns.sequenceNumber.set(to: largestValidSeqNo))

        // Update pendingChange cache based on the `largestValidSeqNo` value
        Task {
            await self.setPendingChanges(pendingChanges.filter {
                $0.seqNo == nil || $0.seqNo! > largestValidSeqNo
            })
        }
        
        return insertedInteractionInfo
    }
    
    nonisolated public func handleDirectMessages(
        _ db: ObservingDatabase,
        messages: [Network.SOGS.DirectMessage],
        fromOutbox: Bool,
        on server: String
    ) -> [MessageReceiver.InsertedInteractionInfo?] {
        // Don't need to do anything if we have no messages (it's a valid case)
        guard !messages.isEmpty else { return [] }
        guard let openGroup: OpenGroup = try? OpenGroup.filter(OpenGroup.Columns.server == server.lowercased()).fetchOne(db) else {
            Log.error(.openGroup, "Couldn't receive inbox message due to missing group.")
            return []
        }
        
        // Sorting the messages by server ID before importing them fixes an issue where messages
        // that quote older messages can't find those older messages
        let sortedMessages: [Network.SOGS.DirectMessage] = messages
            .sorted { lhs, rhs in lhs.id < rhs.id }
        let latestMessageId: Int64 = sortedMessages[sortedMessages.count - 1].id
        var lookupCache: [String: BlindedIdLookup] = [:]  // Only want this cache to exist for the current loop
        var insertedInteractionInfo: [MessageReceiver.InsertedInteractionInfo?] = []
        
        // Update the 'latestMessageId' value
        if fromOutbox {
            _ = try? OpenGroup
                .filter(OpenGroup.Columns.server == server.lowercased())
                .updateAll(db, OpenGroup.Columns.outboxLatestMessageId.set(to: latestMessageId))
        }
        else {
            _ = try? OpenGroup
                .filter(OpenGroup.Columns.server == server.lowercased())
                .updateAll(db, OpenGroup.Columns.inboxLatestMessageId.set(to: latestMessageId))
        }

        // Process the messages
        sortedMessages.forEach { message in
            guard let messageData = Data(base64Encoded: message.base64EncodedMessage) else {
                Log.error(.openGroup, "Couldn't receive inbox message.")
                return
            }

            do {
                let processedMessage: ProcessedMessage = try MessageReceiver.parse(
                    data: messageData,
                    origin: .openGroupInbox(
                        timestamp: message.posted,
                        messageServerId: message.id,
                        serverPublicKey: openGroup.publicKey,
                        senderId: message.sender,
                        recipientId: message.recipient
                    ),
                    using: syncState.dependencies
                )
                try MessageDeduplication.insert(
                    db,
                    processedMessage: processedMessage,
                    ignoreDedupeFiles: false,
                    using: syncState.dependencies
                )
                
                switch processedMessage {
                    case .config, .invalid: break
                    case .standard(let threadId, _, let proto, let messageInfo, _):
                        /// We want to update the BlindedIdLookup cache with the message info so we can avoid using the
                        /// "expensive" lookup when possible
                        let lookup: BlindedIdLookup = try {
                            /// Minor optimisation to avoid processing the same sender multiple times in the same
                            /// 'handleMessages' call (since the 'mapping' call is done within a transaction we
                            /// will never have a mapping come through part-way through processing these messages)
                            if let result: BlindedIdLookup = lookupCache[message.recipient] {
                                return result
                            }
                            
                            return try BlindedIdLookup.fetchOrCreate(
                                db,
                                blindedId: (fromOutbox ?
                                    message.recipient :
                                    message.sender
                                ),
                                sessionId: (fromOutbox ?
                                    nil :
                                    threadId
                                ),
                                openGroupServer: server.lowercased(),
                                openGroupPublicKey: openGroup.publicKey,
                                isCheckingForOutbox: fromOutbox,
                                using: syncState.dependencies
                            )
                        }()
                        lookupCache[message.recipient] = lookup
                        
                        // We also need to set the 'syncTarget' for outgoing messages so the behaviour
                        // to determine the threadId is consistent with standard messages
                        if fromOutbox {
                            let syncTarget: String = (lookup.sessionId ?? message.recipient)
                            
                            switch messageInfo.variant {
                                case .visibleMessage:
                                    (messageInfo.message as? VisibleMessage)?.syncTarget = syncTarget
                                
                                case .expirationTimerUpdate:
                                    (messageInfo.message as? ExpirationTimerUpdate)?.syncTarget = syncTarget
                                
                                default: break
                            }
                        }
                        
                        insertedInteractionInfo.append(
                            try MessageReceiver.handle(
                                db,
                                threadId: (lookup.sessionId ?? lookup.blindedId),
                                threadVariant: .contact,    // Technically not open group messages
                                message: messageInfo.message,
                                serverExpirationTimestamp: messageInfo.serverExpirationTimestamp,
                                associatedWithProto: proto,
                                suppressNotifications: false,
                                using: syncState.dependencies
                            )
                        )
                }
            }
            catch {
                switch error {
                    // Ignore duplicate and self-send errors (we will always receive a duplicate message back
                    // whenever we send a message so this ends up being spam otherwise)
                    case DatabaseError.SQLITE_CONSTRAINT_UNIQUE,
                        DatabaseError.SQLITE_CONSTRAINT,    // Sometimes thrown for UNIQUE
                        MessageReceiverError.duplicateMessage,
                        MessageReceiverError.selfSend:
                        break
                        
                    default:
                        Log.error(.openGroup, "Couldn't receive inbox message due to error: \(error).")
                }
            }
        }
        
        return insertedInteractionInfo
    }
    
    // MARK: - Convenience
    
    nonisolated public func addPendingReaction(
        emoji: String,
        id: Int64,
        in roomToken: String,
        on server: String,
        type: OpenGroupManager.PendingChange.ReactAction
    ) -> OpenGroupManager.PendingChange {
        let pendingChange = OpenGroupManager.PendingChange(
            server: server,
            room: roomToken,
            changeType: .reaction,
            metadata: .reaction(
                messageId: id,
                emoji: emoji,
                action: type
            )
        )
        
        Task { await self.setPendingChanges(pendingChanges.appending(pendingChange)) }
        return pendingChange
    }
    
    private func setPendingChanges(_ pendingChanges: [OpenGroupManager.PendingChange]) {
        self.pendingChanges = pendingChanges
        self.syncState.update(pendingChanges: pendingChanges)
    }
    
    public func updatePendingChange(_ pendingChange: OpenGroupManager.PendingChange, seqNo: Int64?) {
        if let index = pendingChanges.firstIndex(of: pendingChange) {
            pendingChanges[index].seqNo = seqNo
            syncState.update(pendingChanges: pendingChanges)
        }
    }
    
    public func removePendingChange(_ pendingChange: OpenGroupManager.PendingChange) {
        if let index = pendingChanges.firstIndex(of: pendingChange) {
            pendingChanges.remove(at: index)
            syncState.update(pendingChanges: pendingChanges)
        }
    }
    
    /// This method specifies if the given capability is supported on a specified Open Group
    nonisolated public func doesOpenGroupSupport(
        _ db: ObservingDatabase,
        capability: Capability.Variant,
        on server: String?
    ) -> Bool {
        guard let server: String = server else { return false }
        
        let capabilities: [Capability.Variant] = (try? Capability
            .select(.variant)
            .filter(Capability.Columns.openGroupServer == server)
            .filter(Capability.Columns.isMissing == false)
            .asRequest(of: Capability.Variant.self)
            .fetchAll(db))
            .defaulting(to: [])

        return capabilities.contains(capability)
    }
    
    /// This method specifies if the given publicKey is a moderator or an admin within a specified Open Group
    nonisolated public func isUserModeratorOrAdmin(
        _ db: ObservingDatabase,
        publicKey: String,
        for roomToken: String?,
        on server: String?,
        currentUserSessionIds: Set<String>
    ) -> Bool {
        guard let roomToken: String = roomToken, let server: String = server else { return false }
        
        let groupId: String = OpenGroup.idFor(roomToken: roomToken, server: server)
        let targetRoles: [GroupMember.Role] = [.moderator, .admin]
        var possibleKeys: Set<String> = [publicKey]
        
        /// If the `publicKey` is in `currentUserSessionIds` then we want to use `currentUserSessionIds` to do
        /// the lookup
        if currentUserSessionIds.contains(publicKey) {
            possibleKeys = currentUserSessionIds
            
            /// Add the users `unblinded` pubkey if we can get it, just for completeness
            let userEdKeyPair: KeyPair? = syncState.dependencies[singleton: .crypto].generate(
                .ed25519KeyPair(seed: syncState.dependencies[cache: .general].ed25519Seed)
            )
            if let userEdPublicKey: [UInt8] = userEdKeyPair?.publicKey {
                possibleKeys.insert(SessionId(.unblinded, publicKey: userEdPublicKey).hexString)
            }
        }
        
        return GroupMember
            .filter(GroupMember.Columns.groupId == groupId)
            .filter(possibleKeys.contains(GroupMember.Columns.profileId))
            .filter(targetRoles.contains(GroupMember.Columns.role))
            .isNotEmpty(db)
    }
}

// MARK: - Helper Functions

// stringlint:ignore_contents
internal extension OpenGroupManagerType {
    nonisolated fileprivate static func port(for server: String, serverUrl: URL) -> String {
        if let port: Int = serverUrl.port {
            return ":\(port)"
        }
        
        let components: [String] = server.components(separatedBy: ":")
        
        guard
            let port: String = components.last,
            (
                port != components.first &&
                !port.starts(with: "//")
            )
        else { return "" }
        
        return ":\(port)"
    }
    
    nonisolated static func isSessionRunOpenGroup(server: String) -> Bool {
        guard let serverUrl: URL = (URL(string: server.lowercased()) ?? URL(string: "http://\(server.lowercased())")) else {
            return false
        }
        
        let serverPort: String = Self.port(for: server, serverUrl: serverUrl)
        let serverHost: String = serverUrl.host
            .defaulting(
                to: server
                    .lowercased()
                    .replacingOccurrences(of: serverPort, with: "")
            )
        let options: Set<String> = Set([
            Network.SOGS.legacyDefaultServerIP,
            Network.SOGS.defaultServer
                .replacingOccurrences(of: "http://", with: "")
                .replacingOccurrences(of: "https://", with: "")
        ])
        
        return options.contains(serverHost)
    }
}

// MARK: - Deprecated Convenience Functions

public extension OpenGroupManagerType {
    @available(*, deprecated, message: "This function should be avoided as it uses a blocking database query to retrieve the result. Use an async method instead.")
    nonisolated func doesOpenGroupSupport(
        capability: Capability.Variant,
        on server: String?
    ) -> Bool {
        guard let server: String = server else { return false }
        
        var openGroupSupportsCapability: Bool = false
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        syncState.dependencies[singleton: .storage].readAsync(
            retrieve: { [weak self] db in
                self?.doesOpenGroupSupport(db, capability: capability, on: server)
            },
            completion: { result in
                switch result {
                    case .failure: break
                    case .success(let value): openGroupSupportsCapability = (value == true)
                }
                semaphore.signal()
            }
        )
        semaphore.wait()
        return openGroupSupportsCapability
    }
    
    @available(*, deprecated, message: "This function should be avoided as it uses a blocking database query to retrieve the result. Use an async method instead.")
    nonisolated func isUserModeratorOrAdmin(
        publicKey: String,
        for roomToken: String?,
        on server: String?,
        currentUserSessionIds: Set<String>
    ) -> Bool {
        guard let roomToken: String = roomToken, let server: String = server else { return false }
        
        var userIsModeratorOrAdmin: Bool = false
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
        syncState.dependencies[singleton: .storage].readAsync(
            retrieve: { [weak self] db in
                self?.isUserModeratorOrAdmin(
                    db,
                    publicKey: publicKey,
                    for: roomToken,
                    on: server,
                    currentUserSessionIds: currentUserSessionIds
                )
            },
            completion: { result in
                switch result {
                    case .failure: break
                    case .success(let value): userIsModeratorOrAdmin = (value == true)
                }
                semaphore.signal()
            }
        )
        semaphore.wait()
        return userIsModeratorOrAdmin
    }
}

// MARK: - OpenGroupManagerSyncState

/// We manually handle thread-safety using the `NSLock` so can ensure this is `Sendable`
public final class OpenGroupManagerSyncState: @unchecked Sendable {
    private let lock = NSLock()
    public let dependencies: Dependencies
    private var _pendingChanges: [OpenGroupManager.PendingChange] = []
    public var pendingChanges: [OpenGroupManager.PendingChange] { lock.withLock { _pendingChanges } }
    
    init(
        pendingChanges: [OpenGroupManager.PendingChange] = [],
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self._pendingChanges = pendingChanges
    }
    
    func update(pendingChanges: [OpenGroupManager.PendingChange]) {
        lock.withLock { self._pendingChanges = pendingChanges }
    }
}

// MARK: - OpenGroupManagerType

public protocol OpenGroupManagerType: Actor {
    @available(*, deprecated, message: "Should try to refactor the code to use proper async/await")
    nonisolated var syncState: OpenGroupManagerSyncState { get }
    
    var dependencies: Dependencies { get }
    nonisolated var defaultRooms: AsyncStream<[OpenGroupManager.DefaultRoomInfo]> { get }
    var pendingChanges: [OpenGroupManager.PendingChange] { get }
    
    // MARK: - Adding & Removing
    
    nonisolated func hasExistingOpenGroup(
        _ db: ObservingDatabase,
        roomToken: String,
        server: String,
        publicKey: String
    ) -> Bool
    nonisolated func add(
        _ db: ObservingDatabase,
        roomToken: String,
        server: String,
        publicKey: String,
        forceVisible: Bool
    ) -> Bool
    nonisolated func performInitialRequestsAfterAdd(
        queue: DispatchQueue,
        successfullyAddedGroup: Bool,
        roomToken: String,
        server: String,
        publicKey: String
    ) -> AnyPublisher<Void, Error>
    nonisolated func delete(
        _ db: ObservingDatabase,
        openGroupId: String,
        skipLibSessionUpdate: Bool
    ) throws
    
    // MARK: - Default Rooms
    
    func setDefaultRoomInfo(_ info: [OpenGroupManager.DefaultRoomInfo]) async
    
    // MARK: - Polling
    
    func getLastSuccessfulCommunityPollTimestamp() -> TimeInterval
    func setLastSuccessfulCommunityPollTimestamp(_ timestamp: TimeInterval)
    
    // MARK: - Response Processing
    
    nonisolated func handleCapabilities(
        _ db: ObservingDatabase,
        capabilities: Network.SOGS.CapabilitiesResponse,
        on server: String
    )
    nonisolated func handlePollInfo(
        _ db: ObservingDatabase,
        pollInfo: Network.SOGS.RoomPollInfo,
        publicKey maybePublicKey: String?,
        for roomToken: String,
        on server: String
    ) throws
    nonisolated func handleMessages(
        _ db: ObservingDatabase,
        messages: [Network.SOGS.Message],
        for roomToken: String,
        on server: String
    ) -> [MessageReceiver.InsertedInteractionInfo?]
    nonisolated func handleDirectMessages(
        _ db: ObservingDatabase,
        messages: [Network.SOGS.DirectMessage],
        fromOutbox: Bool,
        on server: String
    ) -> [MessageReceiver.InsertedInteractionInfo?]
    
    // MARK: - Convenience
    
    nonisolated func addPendingReaction(
        emoji: String,
        id: Int64,
        in roomToken: String,
        on server: String,
        type: OpenGroupManager.PendingChange.ReactAction
    ) -> OpenGroupManager.PendingChange
    func updatePendingChange(_ pendingChange: OpenGroupManager.PendingChange, seqNo: Int64?)
    func removePendingChange(_ pendingChange: OpenGroupManager.PendingChange)
    
    nonisolated func doesOpenGroupSupport(
        _ db: ObservingDatabase,
        capability: Capability.Variant,
        on server: String?
    ) -> Bool
    nonisolated func isUserModeratorOrAdmin(
        _ db: ObservingDatabase,
        publicKey: String,
        for roomToken: String?,
        on server: String?,
        currentUserSessionIds: Set<String>
    ) -> Bool
}
