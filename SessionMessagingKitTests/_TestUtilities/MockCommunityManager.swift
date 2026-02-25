// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionNetworkingKit
import SessionUtilitiesKit
import TestUtilities

@testable import SessionMessagingKit

class MockCommunityManager: CommunityManagerType, Mockable {
    nonisolated let handler: MockHandler<CommunityManagerType>
    
    required internal init(handler: MockHandler<CommunityManagerType>) {
        self.handler = handler
    }
    
    required internal init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    // MARK: - CommunityManagerType
    
    var dependencies: Dependencies { handler.erasedDependencies as! Dependencies }
    nonisolated var defaultRooms: AsyncStream<(rooms: [Network.SOGS.Room], lastError: Error?)> {
        handler.mock()
    }
    var pendingChanges: [CommunityManager.PendingChange] { handler.mock() }
    nonisolated var syncPendingChanges: [CommunityManager.PendingChange] { handler.mock() }
    
    func getLastSuccessfulCommunityPollTimestamp() async -> TimeInterval {
        return handler.mock()
    }
    
    func setLastSuccessfulCommunityPollTimestamp(_ timestamp: TimeInterval) async {
        handler.mockNoReturn(args: [timestamp])
    }
    
    func fetchDefaultRoomsIfNeeded() async { handler.mockNoReturn() }
    func loadCacheIfNeeded() async { handler.mockNoReturn() }
    
    func server(_ server: String) async -> CommunityManager.Server? {
        return handler.mock(args: [server])
    }
    
    func server(threadId: String) async -> CommunityManager.Server? {
        return handler.mock(args: [threadId])
    }
    
    func serversByThreadId() async -> [String: CommunityManager.Server] {
        return handler.mock()
    }
    
    func updateServer(server: CommunityManager.Server) async {
        return handler.mock(args: [server])
    }
    
    func updatePollFailureCount(_ pollFailureCount: Int64, server: String) async {
        return handler.mock(args: [pollFailureCount, server])
    }
    
    func updateCapabilities(
        capabilities: Set<Capability.Variant>,
        server: String,
        publicKey: String
    ) async {
        handler.mockNoReturn(args: [capabilities, server, publicKey])
    }
    func updateRooms(
        rooms: [Network.SOGS.Room],
        server: String,
        publicKey: String,
        areDefaultRooms: Bool
    ) async {
        handler.mockNoReturn(args: [rooms, server, publicKey, areDefaultRooms])
    }
    
    // MARK: - Adding & Removing
    
    func hasExistingCommunity(roomToken: String, server: String, publicKey: String) async -> Bool {
        return handler.mock(args: [roomToken, server, publicKey])
    }
    
    nonisolated func add(
        _ db: ObservingDatabase,
        roomToken: String,
        server: String,
        publicKey: String,
        joinedAt: TimeInterval,
        forceVisible: Bool
    ) -> Bool {
        return handler.mock(args: [roomToken, server, publicKey, joinedAt, forceVisible])
    }
    
    nonisolated func performInitialRequestsAfterAdd(
        successfullyAddedGroup: Bool,
        roomToken: String,
        server: String,
        publicKey: String
    ) async throws {
        try handler.mockThrowingNoReturn(args: [successfullyAddedGroup, roomToken, server, publicKey])
    }
    
    nonisolated func delete(
        _ db: ObservingDatabase,
        openGroupId: String,
        skipLibSessionUpdate: Bool
    ) throws {
        return try handler.mockThrowingNoReturn(args: [db, openGroupId, skipLibSessionUpdate])
    }
    
    // MARK: - Response Processing
    
    nonisolated func handleCapabilities(
        _ db: ObservingDatabase,
        capabilities: Network.SOGS.CapabilitiesResponse,
        server: String,
        publicKey: String
    ) {
        return handler.mockNoReturn(args: [db, capabilities, server, publicKey])
    }
    nonisolated func handlePollInfo(
        _ db: ObservingDatabase,
        pollInfo: Network.SOGS.RoomPollInfo,
        server: String,
        roomToken: String,
        publicKey: String
    ) throws {
        return try handler.mockThrowingNoReturn(args: [db, pollInfo, server, roomToken, publicKey])
    }
    nonisolated func handleMessages(
        _ db: ObservingDatabase,
        messages: [Network.SOGS.Message],
        server: String,
        roomToken: String,
        currentUserSessionIds: Set<String>
    ) -> [MessageReceiver.InsertedInteractionInfo?] {
        return handler.mock(args: [db, messages, server, roomToken, currentUserSessionIds])
    }
    
    nonisolated func handleDirectMessages(
        _ db: ObservingDatabase,
        messages: [Network.SOGS.DirectMessage],
        fromOutbox: Bool,
        server: String,
        currentUserSessionIds: Set<String>
    ) -> [MessageReceiver.InsertedInteractionInfo?] {
        return handler.mock(args: [db, messages, fromOutbox, server, currentUserSessionIds])
    }
    
    // MARK: - Convenience
    
    func addPendingReaction(
        emoji: String,
        id: Int64,
        server: String,
        roomToken: String,
        type: CommunityManager.PendingChange.ReactAction
    ) async -> CommunityManager.PendingChange {
        return handler.mock(args: [emoji, id, roomToken, server])
    }
    
    func setPendingChanges(_ pendingChanges: [CommunityManager.PendingChange]) async {
        handler.mockNoReturn(args: [pendingChanges])
    }
    func updatePendingChange(_ pendingChange: CommunityManager.PendingChange, seqNo: Int64?) async {
        handler.mockNoReturn(args: [pendingChange, seqNo])
    }
    func removePendingChange(_ pendingChange: CommunityManager.PendingChange) async {
        handler.mockNoReturn(args: [pendingChange])
    }
    
    func doesOpenGroupSupport(
        capability: Capability.Variant,
        server maybeServer: String?
    ) async -> Bool {
        return handler.mock(args: [capability, maybeServer])
    }
    func allModeratorsAndAdmins(
        server maybeServer: String?,
        roomToken: String?,
        includingHidden: Bool
    ) async -> Set<String> {
        return handler.mock(args: [maybeServer, roomToken, includingHidden])
    }
    func isUserModeratorOrAdmin(
        targetUserPublicKey: String,
        server maybeServer: String?,
        roomToken: String?,
        includingHidden: Bool
    ) async -> Bool {
        return handler.mock(args: [targetUserPublicKey, maybeServer, roomToken, includingHidden])
    }
}

// MARK: - Convenience

extension MockCommunityManager {
    func defaultInitialSetup() async throws {
        try await self.when { $0.defaultRooms }.thenReturn(.singleValue(value: ([], nil)))
        try await self.when { await $0.pendingChanges }.thenReturn([])
        try await self.when { $0.syncPendingChanges }.thenReturn([])
        try await self.when { await $0.getLastSuccessfulCommunityPollTimestamp() }.thenReturn(0)
        try await self.when { await $0.setLastSuccessfulCommunityPollTimestamp(.any) }.thenReturn(())
        try await self.when { await $0.fetchDefaultRoomsIfNeeded() }.thenReturn(())
        try await self.when { await $0.loadCacheIfNeeded() }.thenReturn(())
        try await self.when { await $0.server(.any) }.thenReturn(nil)
        try await self.when { await $0.server(threadId: .any) }.thenReturn(nil)
        try await self.when { await $0.serversByThreadId() }.thenReturn([:])
        try await self.when { await $0.updateServer(server: .any) }.thenReturn(())
        try await self.when { await $0.updatePollFailureCount(.any, server: .any) }.thenReturn(())
        try await self
            .when { await $0.updateCapabilities(capabilities: .any, server: .any, publicKey: .any) }
            .thenReturn(())
        try await self
            .when {
                await $0.updateRooms(
                    rooms: .any,
                    server: .any,
                    publicKey: .any,
                    areDefaultRooms: .any
                )
            }
            .thenReturn(())
        try await self
            .when {
                await $0.hasExistingCommunity(
                    roomToken: .any,
                    server: .any,
                    publicKey: .any
                )
            }
            .thenReturn(false)
        try await self
            .when {
                $0.add(
                    .any,
                    roomToken: .any,
                    server: .any,
                    publicKey: .any,
                    joinedAt: .any,
                    forceVisible: .any
                )
            }
            .thenReturn(false)
        try await self
            .when {
                try await $0.performInitialRequestsAfterAdd(
                    successfullyAddedGroup: .any,
                    roomToken: .any,
                    server: .any,
                    publicKey: .any
                )
            }
            .thenReturn(())
        try await self
            .when {
                try $0.delete(
                    .any,
                    openGroupId: .any,
                    skipLibSessionUpdate: .any
                )
            }
            .thenReturn(())
        try await self
            .when {
                $0.handleCapabilities(
                    .any,
                    capabilities: .any,
                    server: .any,
                    publicKey: .any
                )
            }
            .thenReturn(())
        try await self
            .when {
                try $0.handlePollInfo(
                    .any,
                    pollInfo: .any,
                    server: .any,
                    roomToken: .any,
                    publicKey: .any
                )
            }
            .thenReturn(())
        try await self
            .when {
                $0.handleMessages(
                    .any,
                    messages: .any,
                    server: .any,
                    roomToken: .any,
                    currentUserSessionIds: .any
                )
            }
            .thenReturn([])
        try await self
            .when {
                $0.handleDirectMessages(
                    .any,
                    messages: .any,
                    fromOutbox: .any,
                    server: .any,
                    currentUserSessionIds: .any
                )
            }
            .thenReturn([])
        try await self
            .when {
                await $0.addPendingReaction(
                    emoji: .any,
                    id: .any,
                    server: .any,
                    roomToken: .any,
                    type: .any
                )
            }
            .thenReturn(.mock)
        try await self.when { await $0.setPendingChanges(.any) }.thenReturn(())
        try await self.when { await $0.updatePendingChange(.any, seqNo: .any) }.thenReturn(())
        try await self.when { await $0.removePendingChange(.any) }.thenReturn(())
        try await self
            .when { await $0.doesOpenGroupSupport(capability: .any, server: .any) }
            .thenReturn(false)
        try await self
            .when {
                await $0.allModeratorsAndAdmins(
                    server: .any,
                    roomToken: .any,
                    includingHidden: .any
                )
            }
            .thenReturn([])
        try await self
            .when {
                await $0.isUserModeratorOrAdmin(
                    targetUserPublicKey: .any,
                    server: .any,
                    roomToken: .any,
                    includingHidden: .any
                )
            }
            .thenReturn(false)
    }
}
