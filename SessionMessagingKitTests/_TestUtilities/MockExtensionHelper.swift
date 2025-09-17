// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionNetworkingKit
import SessionUtilitiesKit
import TestUtilities

@testable import SessionMessagingKit

class MockExtensionHelper: ExtensionHelperType, Mockable {
    public var handler: MockHandler<ExtensionHelperType>
    
    required init(handler: MockHandler<ExtensionHelperType>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    func deleteCache() {
        handler.mockNoReturn()
    }
    
    // MARK: - User Metadata
    
    func saveUserMetadata(
        sessionId: SessionId,
        ed25519SecretKey: [UInt8],
        unreadCount: Int?
    ) throws {
        try handler.mockThrowingNoReturn(args: [sessionId, ed25519SecretKey, unreadCount])
    }
    
    func loadUserMetadata() -> ExtensionHelper.UserMetadata? {
        return handler.mock()
    }
    
    // MARK: - Deduping
    
    func hasDedupeRecordSinceLastCleared(threadId: String) -> Bool {
        return handler.mock(args: [threadId])
    }
    
    func dedupeRecordExists(threadId: String, uniqueIdentifier: String) -> Bool {
        return handler.mock(args: [threadId, uniqueIdentifier])
    }
    
    func createDedupeRecord(threadId: String, uniqueIdentifier: String) throws {
        return try handler.mockThrowing(args: [threadId, uniqueIdentifier])
    }
    
    func removeDedupeRecord(threadId: String, uniqueIdentifier: String) throws {
        return try handler.mockThrowing(args: [threadId, uniqueIdentifier])
    }
    
    func upsertLastClearedRecord(threadId: String) throws {
        try handler.mockThrowingNoReturn(args: [threadId])
    }
    
    // MARK: - Config Dumps
    
    func lastUpdatedTimestamp(for sessionId: SessionId, variant: ConfigDump.Variant) -> TimeInterval {
        return handler.mock(args: [sessionId, variant])
    }
    
    func replicate(dump: ConfigDump?, replaceExisting: Bool) {
        handler.mockNoReturn(args: [dump, replaceExisting])
    }
    
    func replicateAllConfigDumpsIfNeeded(userSessionId: SessionId, allDumpSessionIds: Set<SessionId>) async {
        handler.mockNoReturn(args: [userSessionId, allDumpSessionIds])
    }
    
    func refreshDumpModifiedDate(sessionId: SessionId, variant: ConfigDump.Variant) {
        handler.mockNoReturn(args: [sessionId, variant])
    }
    
    func loadUserConfigState(
        into cache: LibSessionCacheType,
        userSessionId: SessionId,
        userEd25519SecretKey: [UInt8]
    ) {
        handler.mockNoReturn(args: [cache, userSessionId, userEd25519SecretKey])
    }
    
    func loadGroupConfigStateIfNeeded(
        into cache: LibSessionCacheType,
        swarmPublicKey: String,
        userEd25519SecretKey: [UInt8]
    ) throws -> [ConfigDump.Variant: Bool] {
        return handler.mock(args: [cache, swarmPublicKey, userEd25519SecretKey])
    }
    
    // MARK: - Notification Settings
    
    func replicate(settings: [String: Preferences.NotificationSettings], replaceExisting: Bool) throws {
        try handler.mockThrowingNoReturn(args: [settings, replaceExisting])
    }
    
    func loadNotificationSettings(
        previewType: Preferences.NotificationPreviewType,
        sound: Preferences.Sound
    ) -> [String: Preferences.NotificationSettings]? {
        return handler.mock(args: [previewType, sound])
    }
    
    // MARK: - Messages
    
    func unreadMessageCount() -> Int? {
        return handler.mock()
    }
    
    func saveMessage(_ message: Network.StorageServer.Message?, threadId: String, isUnread: Bool, isMessageRequest: Bool) throws {
        try handler.mockThrowingNoReturn(args: [message, threadId, isUnread, isMessageRequest])
    }
    
    func willLoadMessages() {
        handler.mockNoReturn()
    }
    
    func loadMessages() async throws {
        try handler.mockThrowingNoReturn()
    }
    
    @discardableResult func waitUntilMessagesAreLoaded(timeout: DispatchTimeInterval) async -> Bool {
        return handler.mock(args: [timeout])
    }
}
