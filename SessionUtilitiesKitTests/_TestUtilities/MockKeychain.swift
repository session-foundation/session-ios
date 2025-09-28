// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit
import TestUtilities

class MockKeychain: KeychainStorageType, Mockable {
    public var handler: MockHandler<KeychainStorageType>
    
    required init(handler: MockHandler<KeychainStorageType>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    func string(forKey key: KeychainStorage.StringKey) throws -> String {
        return try handler.mockThrowing(args: [key])
    }
    
    func set(string: String, forKey key: KeychainStorage.StringKey) throws {
        return try handler.mockThrowing(args: [key])
    }
    
    func remove(key: KeychainStorage.StringKey) throws {
        return try handler.mockThrowing(args: [key])
    }
    
    func data(forKey key: KeychainStorage.DataKey) throws -> Data {
        return try handler.mockThrowing(args: [key])
    }
    
    func set(data: Data, forKey key: KeychainStorage.DataKey) throws {
        return try handler.mockThrowing(args: [key])
    }
    
    func remove(key: KeychainStorage.DataKey) throws {
        return try handler.mockThrowing(args: [key])
    }
    
    func removeAll() throws { try handler.mockThrowingNoReturn() }
    
    func migrateLegacyKeyIfNeeded(legacyKey: String, legacyService: String?, toKey key: KeychainStorage.DataKey) throws {
        try handler.mockThrowingNoReturn(args: [legacyKey, legacyService, key])
    }
    
    func getOrGenerateEncryptionKey(
        forKey key: KeychainStorage.DataKey,
        length: Int,
        cat: Log.Category,
        legacyKey: String?,
        legacyService: String?
    ) throws -> Data {
        return try handler.mockThrowing(args: [key, length, cat, legacyKey, legacyService])
    }
}
