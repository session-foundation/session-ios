// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

@testable import SessionMessagingKit

class MockExtensionHelper: Mock<ExtensionHelperType>, ExtensionHelperType {
    func dedupeRecordExists(threadId: String, uniqueIdentifier: String) -> Bool {
        return mock(args: [threadId, uniqueIdentifier])
    }
    
    func createDedupeRecord(threadId: String, uniqueIdentifier: String) throws {
        return try mockThrowing(args: [threadId, uniqueIdentifier])
    }
    
    func removeDedupeRecord(threadId: String, uniqueIdentifier: String) throws {
        return try mockThrowing(args: [threadId, uniqueIdentifier])
    }
    
    func deleteAllDedupeRecords() {
        mockNoReturn()
    }
}
