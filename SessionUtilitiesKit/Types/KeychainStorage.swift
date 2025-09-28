// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit
import KeychainSwift

// MARK: - Singleton

public extension Singleton {
    static let keychain: SingletonConfig<KeychainStorageType> = Dependencies.create(
        identifier: "keychain",
        createInstance: { dependencies, _ in KeychainStorage(using: dependencies) }
    )
}

// MARK: - Log.Category

public extension Log.Category {
    static let keychain: Log.Category = .create("KeychainStorage", defaultLevel: .info)
}

// MARK: - KeychainStorageError

public enum KeychainStorageError: Error {
    case keySpecInvalid
    case keySpecCreationFailed
    case keySpecInaccessible
    case failure(code: Int32?, logCategory: Log.Category, description: String)
    
    public var code: Int32? {
        switch self {
            case .failure(let code, _, _): return code
            default: return nil
        }
    }
}

// MARK: - KeychainStorageType

public protocol KeychainStorageType: AnyObject {
    func string(forKey key: KeychainStorage.StringKey) throws -> String
    func set(string: String, forKey key: KeychainStorage.StringKey) throws
    func remove(key: KeychainStorage.StringKey) throws
    
    func data(forKey key: KeychainStorage.DataKey) throws -> Data
    func set(data: Data, forKey key: KeychainStorage.DataKey) throws
    func remove(key: KeychainStorage.DataKey) throws
    
    func removeAll() throws
    
    func migrateLegacyKeyIfNeeded(legacyKey: String, legacyService: String?, toKey key: KeychainStorage.DataKey) throws
    @discardableResult func getOrGenerateEncryptionKey(
        forKey key: KeychainStorage.DataKey,
        length: Int,
        cat: Log.Category,
        legacyKey: String?,
        legacyService: String?
    ) throws -> Data
}

public extension KeychainStorageType {
    @discardableResult func getOrGenerateEncryptionKey(
        forKey key: KeychainStorage.DataKey,
        length: Int,
        cat: Log.Category
    ) throws -> Data {
        return try getOrGenerateEncryptionKey(
            forKey: key,
            length: length,
            cat: cat,
            legacyKey: nil,
            legacyService: nil
        )
    }
}

// MARK: - KeychainStorage

public class KeychainStorage: KeychainStorageType {
    private let dependencies: Dependencies
    private let keychain: KeychainSwift = {
        let result: KeychainSwift = KeychainSwift()
        result.synchronizable = false // This is the default but better to be explicit
        
        return result
    }()
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Functions
    
    public func string(forKey key: KeychainStorage.StringKey) throws -> String {
        guard let result: String = keychain.get(key.rawValue) else {
            throw KeychainStorageError.failure(
                code: Int32(keychain.lastResultCode),
                logCategory: .keychain,
                description: "Error retrieving string, OSStatusCode: \(keychain.lastResultCode)"
            )
        }
        
        return result
    }

    public func set(string: String, forKey key: KeychainStorage.StringKey) throws {
        guard keychain.set(string, forKey: key.rawValue, withAccess: .accessibleAfterFirstUnlockThisDeviceOnly) else {
            throw KeychainStorageError.failure(
                code: Int32(keychain.lastResultCode),
                logCategory: .keychain,
                description: "Error setting string, OSStatusCode: \(keychain.lastResultCode)"
            )
        }
    }
    
    public func remove(key: KeychainStorage.StringKey) throws {
        try remove(key: key.rawValue)
    }

    public func data(forKey key: KeychainStorage.DataKey) throws -> Data {
        guard let result: Data = keychain.getData(key.rawValue) else {
            throw KeychainStorageError.failure(
                code: Int32(keychain.lastResultCode),
                logCategory: .keychain,
                description: "Error retrieving data, OSStatusCode: \(keychain.lastResultCode)"
            )
        }
        
        return result
    }

    public func set(data: Data, forKey key: KeychainStorage.DataKey) throws {
        guard keychain.set(data, forKey: key.rawValue, withAccess: .accessibleAfterFirstUnlockThisDeviceOnly) else {
            throw KeychainStorageError.failure(
                code: Int32(keychain.lastResultCode),
                logCategory: .keychain,
                description: "Error setting data, OSStatusCode: \(keychain.lastResultCode)"
            )
        }
    }
    
    public func remove(key: KeychainStorage.DataKey) throws {
        try remove(key: key.rawValue)
    }
    
    private func remove(key: String) throws {
        guard keychain.delete(key) else {
            throw KeychainStorageError.failure(
                code: Int32(keychain.lastResultCode),
                logCategory: .keychain,
                description: "Error removing data, OSStatusCode: \(keychain.lastResultCode)"
            )
        }
    }
    
    public func removeAll() throws {
        guard keychain.clear() else {
            throw KeychainStorageError.failure(
                code: Int32(keychain.lastResultCode),
                logCategory: .keychain,
                description: "Error clearing data, OSStatusCode: \(keychain.lastResultCode)"
            )
        }
    }
    
    public func migrateLegacyKeyIfNeeded(legacyKey: String, legacyService: String?, toKey key: KeychainStorage.DataKey) throws {
        // If we already have a value for the given key then do nothing (assume the existing
        // value is correct)
        guard (try? data(forKey: key)) == nil else { return }
        
        var query: [String: Any] = [
          KeychainSwiftConstants.klass       : kSecClassGenericPassword,
          KeychainSwiftConstants.attrAccount : legacyKey,
          KeychainSwiftConstants.matchLimit  : kSecMatchLimitOne
        ]
        query[KeychainSwiftConstants.returnData] = kCFBooleanTrue
        
        if let legacyService: String = legacyService {
            query[(kSecAttrService as String)] = legacyService
        }
        
        if let accessGroup: String = keychain.accessGroup {
            query[KeychainSwiftConstants.accessGroup] = accessGroup
        }
        
        if keychain.synchronizable {
            query[KeychainSwiftConstants.attrSynchronizable] = kSecAttrSynchronizableAny
        }
        
        var result: AnyObject?
        let lastResultCode = withUnsafeMutablePointer(to: &result) {
          SecItemCopyMatching(query as CFDictionary, UnsafeMutablePointer($0))
        }
        
        guard
            lastResultCode == noErr,
            let resultData: Data = result as? Data
        else { return }
        
        // Store the data in the new location
        try set(data: resultData, forKey: key)
        
        // Remove the data from the old location
        SecItemDelete(query as CFDictionary)
    }
    
    @discardableResult public func getOrGenerateEncryptionKey(
        forKey key: KeychainStorage.DataKey,
        length: Int,
        cat: Log.Category,
        legacyKey: String?,
        legacyService: String?
    ) throws -> Data {
        do {
            if let legacyKey: String = legacyKey {
                try? migrateLegacyKeyIfNeeded(
                    legacyKey: legacyKey,
                    legacyService: legacyService,
                    toKey: key
                )
            }
            
            var encryptionKey: Data = try data(forKey: key)
            defer { encryptionKey.resetBytes(in: 0..<encryptionKey.count) }
            
            guard encryptionKey.count == length else { throw KeychainStorageError.keySpecInvalid }
            
            return encryptionKey
        }
        catch {
            switch (error, (error as? KeychainStorageError)?.code) {
                case (KeychainStorageError.keySpecInvalid, _), (_, errSecItemNotFound):
                    // No keySpec was found so we need to generate a new one
                    do {
                        var keySpec: Data = try dependencies[singleton: .crypto]
                            .tryGenerate(.randomBytes(length))
                        defer { keySpec.resetBytes(in: 0..<keySpec.count) } // Reset content immediately after use
                        
                        try dependencies[singleton: .keychain].set(data: keySpec, forKey: key)
                        return keySpec
                    }
                    catch {
                        Log.error(cat, "Setting keychain value failed with error: \(error.localizedDescription)")
                        throw KeychainStorageError.keySpecCreationFailed
                    }
                    
                default:
                    /// Because we use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, the keychain will
                    /// be inaccessible after device restart until device is unlocked for the first time. If the app receives a push
                    /// notification we won't be able to access the keychain to process that notification so we should just error
                    if dependencies[singleton: .appContext].isMainApp || dependencies[singleton: .appContext].isInBackground {
                        let appState: UIApplication.State = dependencies[singleton: .appContext].reportedApplicationState
                        Log.error(cat, "CipherKeySpec inaccessible. New install or no unlock since device restart?, ApplicationState: \(appState.name)")
                        throw KeychainStorageError.keySpecInaccessible
                    }
                    
                    Log.error(cat, "CipherKeySpec inaccessible; not main app.")
                    throw KeychainStorageError.keySpecInaccessible
            }
        }
    }
}

// MARK: - Keys

public extension KeychainStorage {
    struct DataKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
    
    struct StringKey: RawRepresentable, ExpressibleByStringLiteral, Hashable {
        public let rawValue: String
        
        public init(_ rawValue: String) { self.rawValue = rawValue }
        public init?(rawValue: String) { self.rawValue = rawValue }
        public init(stringLiteral value: String) { self.init(value) }
        public init(unicodeScalarLiteral value: String) { self.init(value) }
        public init(extendedGraphemeClusterLiteral value: String) { self.init(value) }
    }
}
