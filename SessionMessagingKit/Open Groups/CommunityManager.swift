// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit
import SessionNetworkingKit

// MARK: - Singleton

public extension Singleton {
    static let communityManager: SingletonConfig<CommunityManagerType> = Dependencies.create(
        identifier: "communityManager",
        createInstance: { dependencies in CommunityManager(using: dependencies) }
    )
}

// MARK: - Log.Category

public extension Log.Category {
    static let communityManager: Log.Category = .create("communityManager", defaultLevel: .info)
}

// MARK: - CommunityManager

public actor CommunityManager: CommunityManagerType {
    private let dependencies: Dependencies
    nonisolated private let syncState: CommunityManagerSyncState
    
    nonisolated private let _defaultRooms: CurrentValueAsyncStream<(rooms: [Network.SOGS.Room], lastError: Error?)> = CurrentValueAsyncStream(([], nil))
    private var _lastSuccessfulCommunityPollTimestamp: TimeInterval?
    private var _hasFetchedDefaultRooms: Bool = false
    private var _hasLoadedCache: Bool = false
    private var _servers: [String: Server] = [:]
    
    nonisolated public var defaultRooms: AsyncStream<(rooms: [Network.SOGS.Room], lastError: Error?)> {
        _defaultRooms.stream
    }
    public var pendingChanges: [PendingChange] = []
    nonisolated public var syncPendingChanges: [CommunityManager.PendingChange] { syncState.pendingChanges }
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.syncState = CommunityManagerSyncState(using: dependencies)
    }
    
    // MARK: - Cache
    
    @available(*, deprecated, message: "Use `getLastSuccessfulCommunityPollTimestamp` instead")
    nonisolated public func getLastSuccessfulCommunityPollTimestampSync() -> TimeInterval {
        if let storedTime: TimeInterval = syncState.lastSuccessfulCommunityPollTimestamp {
            return storedTime
        }
        
        guard let lastPoll: Date = syncState.dependencies[defaults: .standard, key: .lastOpen] else {
            return 0
        }
        
        syncState.update(lastSuccessfulCommunityPollTimestamp: .set(to: lastPoll.timeIntervalSince1970))
        return lastPoll.timeIntervalSince1970
    }
    
    public func getLastSuccessfulCommunityPollTimestamp() async -> TimeInterval {
        if let storedTime: TimeInterval = _lastSuccessfulCommunityPollTimestamp {
            return storedTime
        }
        
        guard let lastPoll: Date = dependencies[defaults: .standard, key: .lastOpen] else {
            return 0
        }
        
        _lastSuccessfulCommunityPollTimestamp = lastPoll.timeIntervalSince1970
        return lastPoll.timeIntervalSince1970
    }
    
    public func setLastSuccessfulCommunityPollTimestamp(_ timestamp: TimeInterval) async {
        dependencies[defaults: .standard, key: .lastOpen] = Date(timeIntervalSince1970: timestamp)
        _lastSuccessfulCommunityPollTimestamp = timestamp
    }
    
    nonisolated public func currentUserSessionIdsSync(_ server: String) -> Set<String> {
        return (
            syncState.servers[server.lowercased()]?.currentUserSessionIds ??
            [syncState.dependencies[cache: .general].sessionId.hexString]
        )
    }
    
    public func fetchDefaultRoomsIfNeeded() async {
        /// If we don't have any default rooms in memory then we haven't fetched this launch so schedule
        /// the `RetrieveDefaultOpenGroupRoomsJob` if one isn't already running
        guard await _defaultRooms.getCurrent().rooms.isEmpty else { return }
        
        RetrieveDefaultOpenGroupRoomsJob.run(using: dependencies)
    }
    
    public func loadCacheIfNeeded() async {
        guard !_hasLoadedCache else { return }
        
        let data: (info: [OpenGroup], capabilities: [Capability], members: [GroupMember]) = (try? await dependencies[singleton: .storage]
            .readAsync { db in
                let openGroups: [OpenGroup] = try OpenGroup.fetchAll(db)
                let ids: [String] = openGroups.map { $0.id }
                
                return (
                    openGroups,
                    try Capability.fetchAll(db),
                    try GroupMember
                        .filter(ids.contains(GroupMember.Columns.groupId))
                        .fetchAll(db)
                )
            })
            .defaulting(to: ([], [], []))
        let rooms: [String: [OpenGroup]] = data.info.grouped(by: \.server)
        let capabilities: [String: [Capability.Variant]] = data.capabilities.reduce(into: [:]) { result, next in
            result.append(next.variant, toArrayOn: next.openGroupServer.lowercased())
        }
        let members: [String: [GroupMember]] = data.members.grouped(by: \.groupId)
        
        _servers = rooms.reduce(into: [:]) { result, next in
            guard let publicKey: String = next.value.first?.publicKey else { return }
            
            let server: String = next.key.lowercased()
            result[server] = CommunityManager.Server(
                server: server,
                publicKey: publicKey,
                openGroups: next.value,
                capabilities: capabilities[server].map { Set($0) },
                roomMembers: next.value.reduce(into: [:]) { result, next in
                    result[next.roomToken] = members[next.threadId]
                },
                using: dependencies
            )
        }
        _hasLoadedCache = true
    }
    
    public func server(_ server: String) async -> Server? {
        return _servers[server.lowercased()]
    }
    
    public func server(threadId: String) async -> Server? {
        return _servers.values.first { server in
            return server.rooms.values.contains {
                OpenGroup.idFor(roomToken: $0.token, server: server.server) == threadId
            }
        }
    }
    
    public func serversByThreadId() async -> [String: CommunityManager.Server] {
        return _servers.values.reduce(into: [:]) { result, server in
            server.rooms.forEach { roomToken, _ in
                result[OpenGroup.idFor(roomToken: roomToken, server: server.server)] = server
            }
        }
    }
    
    public func updateServer(server: Server) async {
        _servers[server.server.lowercased()] = server
    }
    
    public func updateCapabilities(
        capabilities: Set<Capability.Variant>,
        server: String,
        publicKey: String
    ) async {
        switch _servers[server.lowercased()] {
            case .none:
                _servers[server.lowercased()] = CommunityManager.Server(
                    server: server.lowercased(),
                    publicKey: publicKey,
                    openGroups: [],
                    capabilities: capabilities,
                    roomMembers: nil,
                    using: dependencies
                )
                
            case .some(let existingServer):
                _servers[server.lowercased()] = existingServer.with(
                    capabilities: .set(to: capabilities),
                    using: dependencies
                )
        }
    }
    
    public func updateRooms(
        rooms: [Network.SOGS.Room],
        server: String,
        publicKey: String,
        areDefaultRooms: Bool
    ) async {
        /// For default rooms we don't want to replicate or store them alongside other room data, so just emit that we have received
        /// them and stop (since we don't want to poll or interact with these outside of the default rooms UI we want to avoid keeping
        /// them alongside other room data)
        guard !areDefaultRooms else {
            await _defaultRooms.send((rooms, nil))
            return
        }
        
        let targetServer: Server = (
            _servers[server.lowercased()] ??
            CommunityManager.Server(
                server: server.lowercased(),
                publicKey: publicKey,
                openGroups: [],
                capabilities: nil,
                roomMembers: nil,
                using: dependencies
            )
        )
        _servers[server.lowercased()] = targetServer.with(
            rooms: .set(to: rooms),
            using: dependencies
        )
    }
    
    public func removeRoom(server: String, roomToken: String) async {
        let serverString: String = server.lowercased()
        
        guard let server: Server = _servers[serverString] else { return }
        
        _servers[serverString] = server.with(
            rooms: .set(to: Array(server.rooms.removingValue(forKey: roomToken).values)),
            using: dependencies
        )
    }

    // MARK: - Adding & Removing
    
    // stringlint:ignore_contents
    private static func port(for server: String, serverUrl: URL) -> String {
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
    
    public static func isSessionRunCommunity(server: String) -> Bool {
        guard let serverUrl: URL = (URL(string: server.lowercased()) ?? URL(string: "http://\(server.lowercased())")) else {
            return false
        }
        
        let serverPort: String = CommunityManager.port(for: server, serverUrl: serverUrl)
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
    
    nonisolated public func hasExistingCommunity(
        roomToken: String,
        server: String,
        publicKey: String
    ) -> Bool {
        guard let serverUrl: URL = URL(string: server.lowercased()) else { return false }
        
        let serverPort: String = CommunityManager.port(for: server, serverUrl: serverUrl)
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
        
        /// If the server is run by Session then include all configurations in case one of the alternate configurations was used
        if CommunityManager.isSessionRunCommunity(server: server) {
            serverOptions.insert(defaultServerHost)
            serverOptions.insert("http://\(defaultServerHost)")
            serverOptions.insert("https://\(defaultServerHost)")
            serverOptions.insert(Network.SOGS.legacyDefaultServerIP)
            serverOptions.insert("http://\(Network.SOGS.legacyDefaultServerIP)")
            serverOptions.insert("https://\(Network.SOGS.legacyDefaultServerIP)")
        }
        
        /// Check if the result matches an entry in the cache
        let cachedServers: [String: Server] = syncState.servers
        
        return serverOptions.contains { serverName in
            cachedServers[serverName.lowercased()]?.rooms[roomToken] != nil
        }
    }
    
    nonisolated public func add(
        _ db: ObservingDatabase,
        roomToken: String,
        server: String,
        publicKey: String,
        joinedAt: TimeInterval,
        forceVisible: Bool
    ) -> Bool {
        /// No need to do anything if the community is already in the cache
        if hasExistingCommunity(roomToken: roomToken, server: server, publicKey: publicKey) {
            Log.info(.communityManager, "Ignoring join open group attempt (already joined)")
            return false
        }
        
        /// Normalize the server
        let targetServer: String = {
            guard CommunityManager.isSessionRunCommunity(server: server) else {
                return server.lowercased()
            }
            
            return Network.SOGS.defaultServer
        }()
        let threadId: String = OpenGroup.idFor(roomToken: roomToken, server: targetServer)
        
        /// Optionally try to insert a new version of the `OpenGroup` (it will fail if there is already an inactive one but that won't matter
        /// as we then activate it)
        _ = try? SessionThread.upsert(
            db,
            id: threadId,
            variant: .community,
            values: SessionThread.TargetValues(
                creationDateTimestamp: .useExistingOrSetTo(joinedAt),
                /// When adding an open group via config handling then we want to force it to be visible (if it did come via config
                /// handling then we want to wait until it actually has messages before making it visible)
                shouldBeVisible: (forceVisible ? .setTo(true) :  .useExisting)
            ),
            using: syncState.dependencies
        )
        
        /// Update the state to allow polling and reset the `sequenceNumber`
        let openGroup: OpenGroup = OpenGroup
            .fetchOrCreate(db, server: targetServer, roomToken: roomToken, publicKey: publicKey)
            .with(shouldPoll: .set(to: true), sequenceNumber: .set(to: 0))
        try? openGroup.upsert(db)
        
        /// Update the cache to have a record of the new room
        db.afterCommit { [weak self] in
            Task.detached(priority: .userInitiated) {
                let targetRooms: [Network.SOGS.Room]
                
                switch await self?._servers[server.lowercased()] {
                    case .none:
                        targetRooms = [Network.SOGS.Room(openGroup: openGroup)]
                        
                    case .some(let existingServer):
                        targetRooms = (
                            Array(existingServer.rooms.values) + [Network.SOGS.Room(openGroup: openGroup)]
                        )
                }
                
                await self?.updateRooms(
                    rooms: targetRooms,
                    server: openGroup.server,
                    publicKey: openGroup.publicKey,
                    areDefaultRooms: false
                )
            }
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
            !syncState.dependencies[cache: .libSessionNetwork].isSuspended
        else {
            return Just(())
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        // Store the open group information
        let targetServer: String = {
            guard CommunityManager.isSessionRunCommunity(server: server) else {
                return server.lowercased()
            }
            
            return Network.SOGS.defaultServer
        }()
        
        return Result {
            try Network.SOGS
                .preparedCapabilitiesAndRoom(
                    roomToken: roomToken,
                    authMethod: Authentication.Community(
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
                    server: targetServer,
                    publicKey: publicKey
                )
                
                // Then the room
                try handlePollInfo(
                    db,
                    pollInfo: Network.SOGS.RoomPollInfo(room: response.value.room.data),
                    server: targetServer,
                    roomToken: roomToken,
                    publicKey: publicKey,
                )
            }
            .handleEvents(
                receiveCompletion: { [dependencies = syncState.dependencies] result in
                    switch result {
                        case .finished:
                            // (Re)start the poller if needed (want to force it to poll immediately in the next
                            // run loop to avoid a big delay before the next poll)
                            dependencies.mutate(cache: .communityPollers) { cache in
                                let poller: CommunityPollerType = cache.getOrCreatePoller(for: server.lowercased())
                                poller.stop()
                                poller.startIfNeeded()
                            }
                            
                        case .failure(let error): Log.error(.communityManager, "Failed to join open group with error: \(error).")
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
            .filter(OpenGroup.Columns.shouldPoll == true)
            .fetchCount(db))
            .defaulting(to: 1)
        
        if numActiveRooms == 1, let server: String = server?.lowercased() {
            db.afterCommit { [weak self] in
                self?.syncState.dependencies.mutate(cache: .communityPollers) {
                    $0.stopAndRemovePoller(for: server)
                }
            }
        }
        
        // Remove all the data (everything should cascade delete)
        _ = try? Interaction.deleteWhere(db, .filter(Interaction.Columns.threadId == openGroupId))
        _ = try? SessionThread
            .filter(id: openGroupId)
            .deleteAll(db)
        
        db.addConversationEvent(
            id: openGroupId,
            variant: .community,
            type: .deleted
        )
        
        // Remove any dedupe records (we will want to reprocess all OpenGroup messages if they get re-added)
        try MessageDeduplication.deleteIfNeeded(db, threadIds: [openGroupId], using: syncState.dependencies)
        
        // Remove the open group (no foreign key to the thread so it won't auto-delete)
        _ = try? OpenGroup
            .filter(id: openGroupId)
            .deleteAll(db)
        
        // Delete any capabilities associated with the room (no foreign key so it won't auto-delete)
        if numActiveRooms == 1, let server: String = server {
            _ = try? Capability
                .filter(Capability.Columns.openGroupServer == server.lowercased())
                .deleteAll(db)
        }
        
        if let server: String = server, let roomToken: String = roomToken {
            if !skipLibSessionUpdate {
                try LibSession.remove(db, server: server, roomToken: roomToken, using: syncState.dependencies)
            }
            
            db.afterCommit { [weak self] in
                Task.detached(priority: .userInitiated) {
                    await self?.removeRoom(server: server, roomToken: roomToken)
                }
            }
        }
    }
    
    // MARK: - Response Processing
    
    nonisolated public func handleCapabilities(
        _ db: ObservingDatabase,
        capabilities: Network.SOGS.CapabilitiesResponse,
        server: String,
        publicKey: String
    ) {
        // Remove old capabilities first
        _ = try? Capability
            .filter(Capability.Columns.openGroupServer == server.lowercased())
            .deleteAll(db)
        
        // Then insert the new capabilities (both present and missing)
        let newCapabilities: Set<Capability.Variant> = Set(capabilities.capabilities
            .map { Capability.Variant(from: $0) })
        newCapabilities.forEach { variant in
            try? Capability(
                openGroupServer: server.lowercased(),
                variant: variant,
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
        
        /// Update the `CommunityManager` cache
        db.afterCommit { [weak self] in
            Task.detached(priority: .userInitiated) {
                await self?.updateCapabilities(
                    capabilities: newCapabilities,
                    server: server,
                    publicKey: publicKey
                )
            }
        }
    }
    
    nonisolated public func handlePollInfo(
        _ db: ObservingDatabase,
        pollInfo: Network.SOGS.RoomPollInfo,
        server: String,
        roomToken: String,
        publicKey: String
    ) throws {
        // Create the open group model and get or create the thread
        let threadId: String = OpenGroup.idFor(roomToken: roomToken, server: server)
        
        guard let openGroup: OpenGroup = try OpenGroup.fetchOne(db, id: threadId) else { return }
        
        // Only update the database columns which have changed (this is to prevent the UI from triggering
        // updates due to changing database columns to the existing value)
        let hasDetails: Bool = (pollInfo.details != nil)
        let permissions: OpenGroup.Permissions = OpenGroup.Permissions(roomInfo: pollInfo)
        let changes: [ConfigColumnAssignment] = []
            .appending(openGroup.publicKey == publicKey ? nil :
                OpenGroup.Columns.publicKey.set(to: publicKey)
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
            let oldMembers: [GroupMember]? = try? GroupMember
                .filter(GroupMember.Columns.groupId == threadId)
                .fetchAll(db)
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
            
            /// Schedule an event to be sent
            let oldAdmins: Set<String> = Set((oldMembers?
                .filter { $0.role == .admin && !$0.isHidden }
                .map { $0.profileId }) ?? [])
            let oldHiddenAdmins: Set<String> = Set((oldMembers?
                .filter { $0.role == .admin && $0.isHidden }
                .map { $0.profileId }) ?? [])
            let oldMods: Set<String> = Set((oldMembers?
                .filter { $0.role == .moderator && !$0.isHidden }
                .map { $0.profileId }) ?? [])
            let oldHiddenMods: Set<String> = Set((oldMembers?
                .filter { $0.role == .moderator && !$0.isHidden }
                .map { $0.profileId }) ?? [])
            let newAdmins: Set<String> = Set(roomDetails.admins)
            let newHiddenAdmins: Set<String> = Set(roomDetails.hiddenAdmins ?? [])
            let newMods: Set<String> = Set(roomDetails.moderators)
            let newHiddenMods: Set<String> = Set(roomDetails.hiddenModerators ?? [])
            
            if
                oldAdmins != newAdmins ||
                oldHiddenAdmins != newHiddenAdmins ||
                oldMods != newMods ||
                oldHiddenMods != newHiddenMods
            {
                db.addCommunityEvent(
                    id: threadId,
                    change: .moderatorsAndAdmins(
                        admins: Array(newAdmins),
                        hiddenAdmins: Array(newHiddenAdmins),
                        moderators: Array(newMods),
                        hiddenModerators: Array(newHiddenMods)
                    )
                )
            }
            
            /// Update the `CommunityManager` cache
            db.afterCommit { [weak self] in
                Task.detached(priority: .userInitiated) {
                    let targetRooms: [Network.SOGS.Room]
                    
                    switch await self?._servers[server.lowercased()] {
                        case .none:
                            targetRooms = [roomDetails]
                            
                        case .some(let existingServer):
                            targetRooms = (Array(existingServer.rooms.values) + [roomDetails])
                    }
                    
                    await self?.updateRooms(
                        rooms: targetRooms,
                        server: openGroup.server,
                        publicKey: openGroup.publicKey,
                        areDefaultRooms: false
                    )
                }
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
                        timestamp: (syncState.dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000)
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
                    variant: .community,
                    type: .updated(.displayName(pollInfo.details?.name ?? openGroup.name))
                )
            }
            
            if openGroup.roomDescription == pollInfo.details?.roomDescription {
                db.addConversationEvent(
                    id: openGroup.id,
                    variant: .community,
                    type: .updated(.description(pollInfo.details?.roomDescription))
                )
            }
            
            if pollInfo.details?.imageId == nil {
                db.addConversationEvent(
                    id: openGroup.id,
                    variant: .community,
                    type: .updated(.displayPictureUrl(nil))
                )
            }
        }
    }
    
    nonisolated public func handleMessages(
        _ db: ObservingDatabase,
        messages: [Network.SOGS.Message],
        server: String,
        roomToken: String,
        currentUserSessionIds: Set<String>
    ) -> [MessageReceiver.InsertedInteractionInfo?] {
        guard let openGroup: OpenGroup = try? OpenGroup.fetchOne(db, id: OpenGroup.idFor(roomToken: roomToken, server: server)) else {
            Log.error(.communityManager, "Couldn't handle open group messages due to missing group.")
            return []
        }
        
        /// Sorting the messages by server ID before importing them fixes an issue where messages that quote older messages can't
        /// find those older messages
        let previousMessageCount: Int = ((try? Interaction
            .filter(Interaction.Columns.id == openGroup.id)
            .fetchCount(db)) ?? 0)
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
                let sender: String = message.sender,
                let posted: TimeInterval = message.posted
            {
                do {
                    let processedMessage: ProcessedMessage = try MessageReceiver.parse(
                        data: data,
                        origin: .community(
                            openGroupId: openGroup.id,
                            sender: sender,
                            posted: posted,
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
                        case .config: break
                        case .standard(_, _, let messageInfo, _):
                            insertedInteractionInfo.append(
                                try MessageReceiver.handle(
                                    db,
                                    threadId: openGroup.id,
                                    threadVariant: .community,
                                    message: messageInfo.message,
                                    decodedMessage: messageInfo.decodedMessage,
                                    serverExpirationTimestamp: messageInfo.serverExpirationTimestamp,
                                    suppressNotifications: false,
                                    currentUserSessionIds: currentUserSessionIds,
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
                            MessageError.duplicateMessage,
                            MessageError.selfSend:
                            break
                        
                        default:
                            Log.error(.communityManager, "Couldn't receive open group message due to error: \(error).")
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
                        associatedPendingChanges: syncPendingChanges.filter {
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
                    Log.error(.communityManager, "Couldn't handle open group reactions due to error: \(error).")
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
        
        // If we didn't previously have any messages for this community then we should notify that the
        // initial fetch has now been completed
        if previousMessageCount == 0 {
            db.addCommunityEvent(id: openGroup.id, change: .receivedInitialMessages(sortedMessages))
        }
        
        // Now that we've finished processing all valid message changes we can update the `sequenceNumber` to
        // the `largestValidSeqNo` value
        _ = try? OpenGroup
            .filter(id: openGroup.id)
            .updateAll(db, OpenGroup.Columns.sequenceNumber.set(to: largestValidSeqNo))

        // Update pendingChange cache based on the `largestValidSeqNo` value
        db.afterCommit { [weak self] in
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                
                await setPendingChanges(
                    pendingChanges.filter {
                        $0.seqNo == nil || ($0.seqNo ?? 0) > largestValidSeqNo
                    }
                )
                
                let targetRooms: [Network.SOGS.Room]
                
                switch await self.server(server) {
                    case .none:
                        targetRooms = [Network.SOGS.Room(openGroup: openGroup)]
                        
                    case .some(let existingServer):
                        targetRooms = (
                            Array(existingServer.rooms.values) + [Network.SOGS.Room(openGroup: openGroup)]
                        )
                }
                
                await updateRooms(
                    rooms: targetRooms,
                    server: openGroup.server,
                    publicKey: openGroup.publicKey,
                    areDefaultRooms: false
                )
            }
        }
        
        return insertedInteractionInfo
    }
    
    nonisolated public func handleDirectMessages(
        _ db: ObservingDatabase,
        messages: [Network.SOGS.DirectMessage],
        fromOutbox: Bool,
        server: String,
        currentUserSessionIds: Set<String>
    ) -> [MessageReceiver.InsertedInteractionInfo?] {
        // Don't need to do anything if we have no messages (it's a valid case)
        guard !messages.isEmpty else { return [] }
        guard let openGroup: OpenGroup = try? OpenGroup.filter(OpenGroup.Columns.server == server.lowercased()).fetchOne(db) else {
            Log.error(.communityManager, "Couldn't receive inbox message due to missing group.")
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
        
        db.afterCommit { [weak self] in
            Task.detached(priority: .userInitiated) { [weak self] in
                guard let self else { return }
                
                if let server: Server = await self.server(server) {
                    if fromOutbox {
                        await updateServer(
                            server: server.with(
                                outboxLatestMessageId: .set(to: latestMessageId),
                                using: dependencies
                            )
                        )
                    }
                    else {
                        await updateServer(
                            server: server.with(
                                inboxLatestMessageId: .set(to: latestMessageId),
                                using: dependencies
                            )
                        )
                    }
                }
            }
        }

        // Process the messages
        sortedMessages.forEach { message in
            guard let messageData = Data(base64Encoded: message.base64EncodedMessage) else {
                Log.error(.communityManager, "Couldn't receive inbox message.")
                return
            }

            do {
                let processedMessage: ProcessedMessage = try MessageReceiver.parse(
                    data: messageData,
                    origin: .communityInbox(
                        posted: message.posted,
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
                    case .config: break
                    case .standard(let threadId, _, let messageInfo, _):
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
                                decodedMessage: messageInfo.decodedMessage,
                                serverExpirationTimestamp: messageInfo.serverExpirationTimestamp,
                                suppressNotifications: false,
                                currentUserSessionIds: currentUserSessionIds,
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
                        MessageError.duplicateMessage,
                        MessageError.selfSend:
                        break
                        
                    default:
                        Log.error(.communityManager, "Couldn't receive inbox message due to error: \(error).")
                }
            }
        }
        
        return insertedInteractionInfo
    }
    
    // MARK: - Convenience
    
    public func addPendingReaction(
        emoji: String,
        id: Int64,
        in roomToken: String,
        on server: String,
        type: PendingChange.ReactAction
    ) async -> PendingChange {
        let pendingChange: PendingChange = PendingChange(
            server: server,
            room: roomToken,
            changeType: .reaction,
            metadata: .reaction(
                messageId: id,
                emoji: emoji,
                action: type
            )
        )
        pendingChanges.append(pendingChange)
        
        return pendingChange
    }
    
    public func setPendingChanges(_ pendingChanges: [CommunityManager.PendingChange]) async {
        self.pendingChanges = pendingChanges
    }
    
    public func updatePendingChange(_ pendingChange: PendingChange, seqNo: Int64?) async {
        if let index = pendingChanges.firstIndex(of: pendingChange) {
            pendingChanges[index].seqNo = seqNo
        }
    }
    
    public func removePendingChange(_ pendingChange: PendingChange) async {
        if let index = pendingChanges.firstIndex(of: pendingChange) {
            pendingChanges.remove(at: index)
        }
    }
    
    /// This method specifies if the given capability is supported on a specified Open Group
    public func doesOpenGroupSupport(
        capability: Capability.Variant,
        on maybeServer: String?
    ) async -> Bool {
        guard
            let serverString: String = maybeServer,
            let cachedServer: Server = await server(serverString)
        else { return false }
        
        return cachedServer.capabilities.contains(capability)
    }
    
    public func allModeratorsAndAdmins(
        server maybeServer: String?,
        roomToken: String?,
        includingHidden: Bool
    ) async -> Set<String> {
        guard
            let roomToken: String = roomToken,
            let serverString: String = maybeServer,
            let cachedServer: Server = await server(serverString),
            let room: Network.SOGS.Room = cachedServer.rooms[roomToken]
        else { return [] }
        
        return CommunityManager.allModeratorsAndAdmins(room: room, includingHidden: includingHidden)
    }
    
    /// This method specifies if the given publicKey is a moderator or an admin within a specified Open Group
    public func isUserModeratorOrAdmin(
        targetUserPublicKey: String,
        server maybeServer: String?,
        roomToken: String?,
        includingHidden: Bool
    ) async -> Bool {
        guard
            let roomToken: String = roomToken,
            let serverString: String = maybeServer,
            let cachedServer: Server = await server(serverString),
            let room: Network.SOGS.Room = cachedServer.rooms[roomToken]
        else { return false }
        
        /// If the `publicKey` belongs to the current user then we should check against any of their pubkey possibilities
        let possibleKeys: Set<String> = (cachedServer.currentUserSessionIds.contains(targetUserPublicKey) ?
            cachedServer.currentUserSessionIds :
            [targetUserPublicKey]
        )
        
        /// Check if the `publicKey` matches a visible admin or moderator
        let isVisibleModOrAdmin: Bool = (
            !possibleKeys.isDisjoint(with: Set(room.admins)) &&
            !possibleKeys.isDisjoint(with: Set(room.moderators))
        )
        
        /// If they are a visible admin/mod, or we don't want to consider hidden admins/mods, then no need to continue
        if isVisibleModOrAdmin || !includingHidden {
            return isVisibleModOrAdmin
        }
        
        /// Chcek if the `publicKey` is a hidden admin/mod
        return (
            !possibleKeys.isDisjoint(with: Set(room.hiddenAdmins ?? [])) &&
            !possibleKeys.isDisjoint(with: Set(room.hiddenModerators ?? []))
        )
    }
}

public extension CommunityManagerType {
    static func allModeratorsAndAdmins(
        room: Network.SOGS.Room,
        includingHidden: Bool
    ) -> Set<String> {
        var result: Set<String> = Set(room.admins + room.moderators)
        
        if includingHidden {
            result.insert(contentsOf: Set(room.hiddenAdmins ?? []))
            result.insert(contentsOf: Set(room.hiddenModerators ?? []))
        }
        
        return result
    }
}

// MARK: - SyncState

private final class CommunityManagerSyncState {
    private let lock: NSLock = NSLock()
    private let _dependencies: Dependencies
    private var _servers: [String: CommunityManager.Server] = [:]
    private var _pendingChanges: [CommunityManager.PendingChange] = []
    
    @available(*, deprecated, message: "Remove this alongside 'getLastSuccessfulCommunityPollTimestampSync'")
    private var _lastSuccessfulCommunityPollTimestamp: TimeInterval? = nil
    
    fileprivate var dependencies: Dependencies { lock.withLock { _dependencies } }
    fileprivate var servers: [String: CommunityManager.Server] { lock.withLock { _servers } }
    fileprivate var pendingChanges: [CommunityManager.PendingChange] { lock.withLock { _pendingChanges } }
    fileprivate var lastSuccessfulCommunityPollTimestamp: TimeInterval? {
        lock.withLock { _lastSuccessfulCommunityPollTimestamp }
    }
    
    fileprivate init(using dependencies: Dependencies) {
        self._dependencies = dependencies
    }
    
    fileprivate func update(
        servers: Update<[String: CommunityManager.Server]> = .useExisting,
        pendingChanges: Update<[CommunityManager.PendingChange]> = .useExisting,
        lastSuccessfulCommunityPollTimestamp: Update<TimeInterval?> = .useExisting,
    ) {
        lock.withLock {
            self._servers = servers.or(self._servers)
            self._pendingChanges = pendingChanges.or(self._pendingChanges)
            self._lastSuccessfulCommunityPollTimestamp = lastSuccessfulCommunityPollTimestamp
                .or(self._lastSuccessfulCommunityPollTimestamp)
        }
    }
}

// MARK: - CommunityManagerType

public protocol CommunityManagerType {
    nonisolated var defaultRooms: AsyncStream<(rooms: [Network.SOGS.Room], lastError: Error?)> { get }
    var pendingChanges: [CommunityManager.PendingChange] { get async }
    nonisolated var syncPendingChanges: [CommunityManager.PendingChange] { get }
    
    // MARK: - Cache
    
    nonisolated func getLastSuccessfulCommunityPollTimestampSync() -> TimeInterval
    func getLastSuccessfulCommunityPollTimestamp() async -> TimeInterval
    func setLastSuccessfulCommunityPollTimestamp(_ timestamp: TimeInterval) async
    
    @available(*, deprecated, message: "use `server(_:)?.currentUserSessionIds` instead")
    nonisolated func currentUserSessionIdsSync(_ server: String) -> Set<String>
    
    func fetchDefaultRoomsIfNeeded() async
    func loadCacheIfNeeded() async
    
    func server(_ server: String) async -> CommunityManager.Server?
    func server(threadId: String) async -> CommunityManager.Server?
    func serversByThreadId() async -> [String: CommunityManager.Server]
    func updateServer(server: CommunityManager.Server) async
    func updateCapabilities(
        capabilities: Set<Capability.Variant>,
        server: String,
        publicKey: String
    ) async
    func updateRooms(
        rooms: [Network.SOGS.Room],
        server: String,
        publicKey: String,
        areDefaultRooms: Bool
    ) async
    
    // MARK: - Adding & Removing
    
    func hasExistingCommunity(roomToken: String, server: String, publicKey: String) async -> Bool
    
    nonisolated func add(
        _ db: ObservingDatabase,
        roomToken: String,
        server: String,
        publicKey: String,
        joinedAt: TimeInterval,
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
    
    // MARK: - Response Processing
    
    nonisolated func handleCapabilities(
        _ db: ObservingDatabase,
        capabilities: Network.SOGS.CapabilitiesResponse,
        server: String,
        publicKey: String
    )
    nonisolated func handlePollInfo(
        _ db: ObservingDatabase,
        pollInfo: Network.SOGS.RoomPollInfo,
        server: String,
        roomToken: String,
        publicKey: String
    ) throws
    nonisolated func handleMessages(
        _ db: ObservingDatabase,
        messages: [Network.SOGS.Message],
        server: String,
        roomToken: String,
        currentUserSessionIds: Set<String>
    ) -> [MessageReceiver.InsertedInteractionInfo?]
    nonisolated func handleDirectMessages(
        _ db: ObservingDatabase,
        messages: [Network.SOGS.DirectMessage],
        fromOutbox: Bool,
        server: String,
        currentUserSessionIds: Set<String>
    ) -> [MessageReceiver.InsertedInteractionInfo?]
    
    // MARK: - Convenience
    
    func addPendingReaction(
        emoji: String,
        id: Int64,
        in roomToken: String,
        on server: String,
        type: CommunityManager.PendingChange.ReactAction
    ) async -> CommunityManager.PendingChange
    func setPendingChanges(_ pendingChanges: [CommunityManager.PendingChange]) async
    func updatePendingChange(_ pendingChange: CommunityManager.PendingChange, seqNo: Int64?) async
    func removePendingChange(_ pendingChange: CommunityManager.PendingChange) async
    
    func doesOpenGroupSupport(
        capability: Capability.Variant,
        on maybeServer: String?
    ) async -> Bool
    func allModeratorsAndAdmins(
        server maybeServer: String?,
        roomToken: String?,
        includingHidden: Bool
    ) async -> Set<String>
    func isUserModeratorOrAdmin(
        targetUserPublicKey: String,
        server maybeServer: String?,
        roomToken: String?,
        includingHidden: Bool
    ) async -> Bool
}

// MARK: - Observations

// stringlint:ignore_contents
public extension ObservableKey {
    static func communityUpdated(_ id: String) -> ObservableKey {
        ObservableKey("communityUpdated-\(id)", .communityUpdated)
    }
}

// stringlint:ignore_contents
public extension GenericObservableKey {
    static let communityUpdated: GenericObservableKey = "communityUpdated"
}

// MARK: - Event Payloads - Conversations

public struct CommunityEvent: Hashable {
    public let id: String
    public let change: Change
    
    public enum Change: Hashable {
        case receivedInitialMessages([Network.SOGS.Message])
        case capabilities([Capability.Variant])
        case permissions(read: Bool, write: Bool, upload: Bool)
        case role(moderator: Bool, admin: Bool, hiddenModerator: Bool, hiddenAdmin: Bool)
        case moderatorsAndAdmins(admins: [String], hiddenAdmins: [String], moderators: [String], hiddenModerators: [String])
    }
}

public extension ObservingDatabase {
    func addCommunityEvent(id: String, change: CommunityEvent.Change) {
        let event: CommunityEvent = CommunityEvent(id: id, change: change)
        addEvent(ObservedEvent(key: .communityUpdated(id), value: event))
    }
}
