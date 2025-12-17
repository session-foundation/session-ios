// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionNetworkingKit
import SessionUtilitiesKit

@testable import SessionMessagingKit

class MockCommunityManager: Mock<CommunityManagerType>, CommunityManagerType {
    nonisolated var defaultRooms: AsyncStream<(rooms: [Network.SOGS.Room], lastError: Error?)> {
        mock()
    }
    var pendingChanges: [CommunityManager.PendingChange] {
        get async { mock() }
    }
    nonisolated var syncPendingChanges: [CommunityManager.PendingChange] {
        mock()
    }
    
    // MARK: - Cache
    
    nonisolated func getLastSuccessfulCommunityPollTimestampSync() -> TimeInterval {
        return mock()
    }
    
    func getLastSuccessfulCommunityPollTimestamp() async -> TimeInterval {
        return mock()
    }
    
    func setLastSuccessfulCommunityPollTimestamp(_ timestamp: TimeInterval) async {
        return mockNoReturn(args: [timestamp])
    }
    
    @available(*, deprecated, message: "use `server(_:)?.currentUserSessionIds` instead")
    nonisolated func currentUserSessionIdsSync(_ server: String) -> Set<String> {
        return mock(args: [server])
    }
    
    func fetchDefaultRoomsIfNeeded() async { mockNoReturn() }
    func loadCacheIfNeeded() async { mockNoReturn() }
    
    func server(_ server: String) async -> CommunityManager.Server? { return mock(args: [server]) }
    func server(threadId: String) async -> CommunityManager.Server? { return mock(args: [threadId]) }
    func serversByThreadId() async -> [String: CommunityManager.Server] { return mock() }
    func updateServer(server: CommunityManager.Server) async { return mock(args: [server]) }
    func updateCapabilities(
        capabilities: Set<Capability.Variant>,
        server: String,
        publicKey: String
    ) async {
        mockNoReturn(args: [capabilities, server, publicKey])
    }
    func updateRooms(
        rooms: [Network.SOGS.Room],
        server: String,
        publicKey: String,
        areDefaultRooms: Bool
    ) async {
        mockNoReturn(args: [rooms, server, publicKey, areDefaultRooms])
    }
    
    // MARK: - Adding & Removing
    
    func hasExistingCommunity(roomToken: String, server: String, publicKey: String) async -> Bool {
        return mock(args: [roomToken, server, publicKey])
    }
    
    nonisolated func add(
        _ db: ObservingDatabase,
        roomToken: String,
        server: String,
        publicKey: String,
        joinedAt: TimeInterval,
        forceVisible: Bool
    ) -> Bool {
        return mock(args: [roomToken, server, publicKey, joinedAt, forceVisible])
    }
    
    nonisolated func performInitialRequestsAfterAdd(
        queue: DispatchQueue,
        successfullyAddedGroup: Bool,
        roomToken: String,
        server: String,
        publicKey: String
    ) -> AnyPublisher<Void, Error> {
        return mock(args: [successfullyAddedGroup, roomToken, server, publicKey], untrackedArgs: [queue])
    }
    
    nonisolated func delete(
        _ db: ObservingDatabase,
        openGroupId: String,
        skipLibSessionUpdate: Bool
    ) throws {
        return try mockThrowingNoReturn(args: [db, openGroupId, skipLibSessionUpdate])
    }
    
    // MARK: - Response Processing
    
    nonisolated func handleCapabilities(
        _ db: ObservingDatabase,
        capabilities: Network.SOGS.CapabilitiesResponse,
        server: String,
        publicKey: String
    ) {
        return mockNoReturn(args: [db, capabilities, server, publicKey])
    }
    nonisolated func handlePollInfo(
        _ db: ObservingDatabase,
        pollInfo: Network.SOGS.RoomPollInfo,
        server: String,
        roomToken: String,
        publicKey: String
    ) throws {
        return try mockThrowingNoReturn(args: [db, pollInfo, server, roomToken, publicKey])
    }
    nonisolated func handleMessages(
        _ db: ObservingDatabase,
        messages: [Network.SOGS.Message],
        server: String,
        roomToken: String,
        currentUserSessionIds: Set<String>
    ) -> [MessageReceiver.InsertedInteractionInfo?] {
        return mock(args: [db, messages, server, roomToken, currentUserSessionIds])
    }
    
    nonisolated func handleDirectMessages(
        _ db: ObservingDatabase,
        messages: [Network.SOGS.DirectMessage],
        fromOutbox: Bool,
        server: String,
        currentUserSessionIds: Set<String>
    ) -> [MessageReceiver.InsertedInteractionInfo?] {
        return mock(args: [db, messages, fromOutbox, server, currentUserSessionIds])
    }
    
    // MARK: - Convenience
    
    func addPendingReaction(
        emoji: String,
        id: Int64,
        in roomToken: String,
        on server: String,
        type: CommunityManager.PendingChange.ReactAction
    ) async -> CommunityManager.PendingChange {
        return mock(args: [emoji, id, roomToken, server])
    }
    
    func setPendingChanges(_ pendingChanges: [CommunityManager.PendingChange]) async {
        mockNoReturn(args: [pendingChanges])
    }
    func updatePendingChange(_ pendingChange: CommunityManager.PendingChange, seqNo: Int64?) async {
        mockNoReturn(args: [pendingChange, seqNo])
    }
    func removePendingChange(_ pendingChange: CommunityManager.PendingChange) async {
        mockNoReturn(args: [pendingChange])
    }
    
    func doesOpenGroupSupport(
        capability: Capability.Variant,
        on maybeServer: String?
    ) async -> Bool {
        return mock(args: [capability, maybeServer])
    }
    func allModeratorsAndAdmins(
        server maybeServer: String?,
        roomToken: String?,
        includingHidden: Bool
    ) async -> Set<String> {
        return mock(args: [maybeServer, roomToken, includingHidden])
    }
    func isUserModeratorOrAdmin(
        targetUserPublicKey: String,
        server maybeServer: String?,
        roomToken: String?,
        includingHidden: Bool
    ) async -> Bool {
        return mock(args: [targetUserPublicKey, maybeServer, roomToken, includingHidden])
    }
}
