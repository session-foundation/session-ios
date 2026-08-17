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
    /// The app group identifier, which doubles as a keychain access group
    ///
    /// Unlike `keychain-access-groups` and `application-identifier`, an app group identifier carries no team ID
    /// prefix on iOS, so items written here remain reachable when the team ID changes
    var appGroupAccessGroup: String { get }

    func data(forKey key: KeychainStorage.DataKey) throws -> Data
    func set(data: Data, forKey key: KeychainStorage.DataKey) throws
    func remove(key: KeychainStorage.DataKey) throws

    /// Read scoped to a single access group
    ///
    /// An unscoped read searches **every** access group the app belongs to, so it cannot distinguish an item in
    /// the app group from the same item in the team-prefixed default group - scoping is the only way to assert
    /// which group an item actually occupies
    func data(forKey key: KeychainStorage.DataKey, accessGroup: String) throws -> Data
    func set(data: Data, forKey key: KeychainStorage.DataKey, accessGroup: String) throws

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

    /// `KeychainSwift` applies its `accessGroup` to every query it builds, so a scoped instance is the mechanism
    /// for reading and writing a specific group rather than the app's whole access group list
    @ThreadSafeObject private var scopedKeychains: [String: KeychainSwift] = [:]

    public var appGroupAccessGroup: String { UserDefaults.applicationGroup }

    // MARK: - Initialization

    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    private func keychain(for accessGroup: String) -> KeychainSwift {
        if let existing: KeychainSwift = scopedKeychains[accessGroup] { return existing }

        let result: KeychainSwift = KeychainSwift()
        result.synchronizable = false
        result.accessGroup = accessGroup
        _scopedKeychains.performUpdate { current in
            var updated: [String: KeychainSwift] = current
            updated[accessGroup] = result
            return updated
        }

        return result
    }
    
    // MARK: - Functions
    
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

        /// Mirror into the app group's access group, because a write here removes the app group's copy first
        ///
        /// An unscoped write deletes before it adds, and an unscoped delete spans **every** access group the app belongs
        /// to - so without this, any write silently un-migrates the key and leaves it reachable only from the
        /// team-prefixed group, which is the group a change of team ID takes away. Mirroring at this level rather than at
        /// each call site is deliberate: there are three unscoped writers today and this covers future ones too
        ///
        /// A failure here must not fail the write the caller asked for. The item is still readable, and
        /// `KeychainAccessGroupMigration` re-mirrors it on the next launch
        do { try set(data: data, forKey: key, accessGroup: appGroupAccessGroup) }
        catch {
            Log.warn(.keychain, "Failed to mirror \(key.rawValue) into the app group access group: \(error)")
        }
    }
    
    public func remove(key: KeychainStorage.DataKey) throws {
        try remove(key: key.rawValue)
    }

    public func data(forKey key: KeychainStorage.DataKey, accessGroup: String) throws -> Data {
        let scoped: KeychainSwift = keychain(for: accessGroup)

        guard let result: Data = scoped.getData(key.rawValue) else {
            throw KeychainStorageError.failure(
                code: Int32(scoped.lastResultCode),
                logCategory: .keychain,
                description: "Error retrieving data for access group, OSStatusCode: \(scoped.lastResultCode)"
            )
        }

        return result
    }

    public func set(data: Data, forKey key: KeychainStorage.DataKey, accessGroup: String) throws {
        let scoped: KeychainSwift = keychain(for: accessGroup)

        guard scoped.set(data, forKey: key.rawValue, withAccess: .accessibleAfterFirstUnlockThisDeviceOnly) else {
            throw KeychainStorageError.failure(
                code: Int32(scoped.lastResultCode),
                logCategory: .keychain,
                description: "Error setting data for access group, OSStatusCode: \(scoped.lastResultCode)"
            )
        }
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
    
}
