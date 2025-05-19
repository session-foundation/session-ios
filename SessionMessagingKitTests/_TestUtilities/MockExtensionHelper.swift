// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionSnodeKit
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
    
    func hasAtLeastOneDedupeRecord(threadId: String) -> Bool {
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
    
    // MARK: - Config Dumps
    
    func lastUpdatedTimestamp(for sessionId: SessionId, variant: ConfigDump.Variant) -> TimeInterval {
        return mock(args: [sessionId, variant])
    }
    
    func replicate(dump: ConfigDump?, replaceExisting: Bool) {
        mockNoReturn(args: [dump, replaceExisting])
    }
    
    func replicateAllConfigDumpsIfNeeded(userSessionId: SessionId) {
        mockNoReturn(args: [userSessionId])
    }
    
    func refreshDumpModifiedDate(sessionId: SessionId, variant: ConfigDump.Variant) {
        mockNoReturn(args: [sessionId, variant])
    }
    
    // MARK: - Messages
    
    func unreadMessageCount() -> Int? {
        return mock()
    }
    
    func saveMessage(_ message: SnodeReceivedMessage?, isUnread: Bool) throws {
        try mockThrowingNoReturn(args: [message, isUnread])
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
