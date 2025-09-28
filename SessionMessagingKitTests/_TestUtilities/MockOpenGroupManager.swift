// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionNetworkingKit
import SessionUtilitiesKit
import TestUtilities

@testable import SessionMessagingKit

actor MockOpenGroupManager: OpenGroupManagerType, Mockable {
    nonisolated let handler: MockHandler<OpenGroupManagerType>
    var dependencies: Dependencies { handler.erasedDependencies as! Dependencies }
    nonisolated var syncState: OpenGroupManagerSyncState { handler.mock() }
    nonisolated var defaultRooms: AsyncStream<[OpenGroupManager.DefaultRoomInfo]> { handler.mock() }
    var pendingChanges: [OpenGroupManager.PendingChange] { handler.mock() }
    
    internal init(handler: MockHandler<OpenGroupManagerType>) {
        self.handler = handler
    }
    
    internal init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    nonisolated func hasExistingOpenGroup(
        _ db: ObservingDatabase,
        roomToken: String,
        server: String,
        publicKey: String
    ) -> Bool {
        return handler.mock(args: [db, roomToken, server, publicKey])
    }
    
    nonisolated func add(
        _ db: ObservingDatabase,
        roomToken: String,
        server: String,
        publicKey: String,
        forceVisible: Bool
    ) -> Bool {
        return handler.mock(args: [db, roomToken, server, publicKey, forceVisible])
    }
    
    nonisolated func performInitialRequestsAfterAdd(
        queue: DispatchQueue,
        successfullyAddedGroup: Bool,
        roomToken: String,
        server: String,
        publicKey: String
    ) -> AnyPublisher<Void, Error> {
        return handler.mock(args: [queue, successfullyAddedGroup, roomToken, server, publicKey])
    }
    
    nonisolated func delete(
        _ db: ObservingDatabase,
        openGroupId: String,
        skipLibSessionUpdate: Bool
    ) throws {
        try handler.mockThrowingNoReturn(args: [db, openGroupId, skipLibSessionUpdate])
    }
    
    func setDefaultRoomInfo(_ info: [OpenGroupManager.DefaultRoomInfo]) async {
        handler.mockNoReturn(args: [info])
    }
    
    func getLastSuccessfulCommunityPollTimestamp() -> TimeInterval {
        return handler.mock()
    }
    
    func setLastSuccessfulCommunityPollTimestamp(_ timestamp: TimeInterval) {
        handler.mockNoReturn(args: [timestamp])
    }
    
    nonisolated func handleCapabilities(
        _ db: ObservingDatabase,
        capabilities: Network.SOGS.CapabilitiesResponse,
        on server: String
    ) {
        handler.mockNoReturn(args: [db, capabilities, server])
    }
    
    nonisolated func handlePollInfo(
        _ db: ObservingDatabase,
        pollInfo: Network.SOGS.RoomPollInfo,
        publicKey maybePublicKey: String?,
        for roomToken: String,
        on server: String
    ) throws {
        try handler.mockThrowingNoReturn(args: [db, pollInfo, maybePublicKey, roomToken, server])
    }
    
    nonisolated func handleMessages(
        _ db: ObservingDatabase,
        messages: [Network.SOGS.Message],
        for roomToken: String,
        on server: String
    ) -> [MessageReceiver.InsertedInteractionInfo?] {
        return handler.mock(args: [db, messages, roomToken, server])
    }
    
    nonisolated func handleDirectMessages(
        _ db: ObservingDatabase,
        messages: [Network.SOGS.DirectMessage],
        fromOutbox: Bool,
        on server: String
    ) -> [MessageReceiver.InsertedInteractionInfo?] {
        return handler.mock(args: [db, messages, fromOutbox, server])
    }
    
    nonisolated func addPendingReaction(
        emoji: String,
        id: Int64,
        in roomToken: String,
        on server: String,
        type: OpenGroupManager.PendingChange.ReactAction
    ) -> OpenGroupManager.PendingChange {
        return handler.mock(args: [emoji, id, roomToken, server, type])
    }
    
    func updatePendingChange(_ pendingChange: OpenGroupManager.PendingChange, seqNo: Int64?) {
        return handler.mock(args: [pendingChange, seqNo])
    }
    
    func removePendingChange(_ pendingChange: OpenGroupManager.PendingChange) {
        return handler.mockNoReturn(args: [pendingChange])
    }
    
    nonisolated func doesOpenGroupSupport(
        _ db: ObservingDatabase,
        capability: Capability.Variant,
        on server: String?
    ) -> Bool {
        return handler.mock(args: [db, capability, server])
    }
    
    nonisolated func isUserModeratorOrAdmin(
        _ db: ObservingDatabase,
        publicKey: String,
        for roomToken: String?,
        on server: String?,
        currentUserSessionIds: Set<String>
    ) -> Bool {
        return handler.mock(args: [db, publicKey, roomToken, server, currentUserSessionIds])
    }
}

// MARK: - Convenience

extension MockOpenGroupManager {
    func defaultInitialSetup() async throws {
        try await self.when { await $0.pendingChanges }.thenReturn([])
        try await self
            .when { $0.syncState }
            .thenReturn(
                OpenGroupManagerSyncState(
                    pendingChanges: [],
                    using: dependencies
                )
            )
        try await self.when { await $0.getLastSuccessfulCommunityPollTimestamp() }.thenReturn(0)
        try await self.when { await $0.setDefaultRoomInfo(.any) }.thenReturn(())
        try await self.when { $0.handleCapabilities(.any, capabilities: .any, on: .any) }.thenReturn(())
    }
}
