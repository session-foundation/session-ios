// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionNetworkingKit
import SessionUtilitiesKit

@testable import SessionMessagingKit

class MockExtensionHelper: Mock<ExtensionHelperType>, ExtensionHelperType {
    func deleteCache() {
        mockNoReturn()
    }
    
    // MARK: - User Metadata
    
    func saveUserMetadata(
        sessionId: SessionId,
        ed25519SecretKey: [UInt8],
        unreadCount: Int?
    ) throws {
        try mockThrowingNoReturn(args: [sessionId, ed25519SecretKey, unreadCount])
    }
    
    func loadUserMetadata() -> ExtensionHelper.UserMetadata? {
        return mock()
    }
    
    // MARK: - Deduping
    
    func hasDedupeRecordSinceLastCleared(threadId: String) -> Bool {
        return mock(args: [threadId])
    }
    
    func dedupeRecordExists(threadId: String, uniqueIdentifier: String) -> Bool {
        return mock(args: [threadId, uniqueIdentifier])
    }
    
    func createDedupeRecord(threadId: String, uniqueIdentifier: String) throws {
        return try mockThrowing(args: [threadId, uniqueIdentifier])
    }
    
    func removeDedupeRecord(threadId: String, uniqueIdentifier: String) throws {
        return try mockThrowing(args: [threadId, uniqueIdentifier])
    }
    
    func upsertLastClearedRecord(threadId: String) throws {
        try mockThrowingNoReturn(args: [threadId])
    }
    
    // MARK: - Config Dumps
    
    func lastUpdatedTimestamp(for sessionId: SessionId, variant: ConfigDump.Variant) -> TimeInterval {
        return mock(args: [sessionId, variant])
    }
    
    func replicate(dump: ConfigDump?, replaceExisting: Bool) {
        mockNoReturn(args: [dump, replaceExisting])
    }
    
    func replicateAllConfigDumpsIfNeeded(userSessionId: SessionId, allDumpSessionIds: Set<SessionId>) {
        mockNoReturn(args: [userSessionId, allDumpSessionIds])
    }
    
    func refreshDumpModifiedDate(sessionId: SessionId, variant: ConfigDump.Variant) {
        mockNoReturn(args: [sessionId, variant])
    }
    
    func loadUserConfigState(
        into cache: LibSessionCacheType,
        userSessionId: SessionId,
        userEd25519SecretKey: [UInt8]
    ) {
        mockNoReturn(args: [cache, userSessionId, userEd25519SecretKey])
    }
    
    func loadGroupConfigStateIfNeeded(
        into cache: LibSessionCacheType,
        swarmPublicKey: String,
        userEd25519SecretKey: [UInt8]
    ) throws -> [ConfigDump.Variant: Bool] {
        return mock(args: [cache, swarmPublicKey, userEd25519SecretKey])
    }
    
    // MARK: - Notification Settings
    
    func replicate(settings: [String: Preferences.NotificationSettings], replaceExisting: Bool) throws {
        try mockThrowingNoReturn(args: [settings, replaceExisting])
    }
    
    func loadNotificationSettings(
        previewType: Preferences.NotificationPreviewType,
        sound: Preferences.Sound
    ) -> [String: Preferences.NotificationSettings]? {
        return mock(args: [previewType, sound])
    }
    
    // MARK: - Messages
    
    func unreadMessageCount() -> Int? {
        return mock()
    }
    
    func saveMessage(_ message: SnodeReceivedMessage?, threadId: String, isUnread: Bool, isMessageRequest: Bool) throws {
        try mockThrowingNoReturn(args: [message, threadId, isUnread, isMessageRequest])
    }
    
    func willLoadMessages() {
        mockNoReturn()
    }
    
    func loadMessages() async throws {
        try mockThrowingNoReturn()
    }
    
    @discardableResult func waitUntilMessagesAreLoaded(timeout: DispatchTimeInterval) async -> Bool {
        return mock(args: [timeout])
    }
}
