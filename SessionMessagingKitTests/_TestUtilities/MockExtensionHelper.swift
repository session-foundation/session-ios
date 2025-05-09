// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

@testable import SessionMessagingKit

class MockExtensionHelper: Mock<ExtensionHelperType>, ExtensionHelperType {
    func deleteCache() {
        mockNoReturn()
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
}
