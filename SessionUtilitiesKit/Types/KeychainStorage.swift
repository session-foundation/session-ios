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
    private let security: SecurityFunctions
    private let keychain: KeychainSwift = {
        let result: KeychainSwift = KeychainSwift()
        result.synchronizable = false // This is the default but better to be explicit

        return result
    }()

    public var appGroupAccessGroup: String { UserDefaults.applicationGroup }

    // MARK: - Initialization

    init(using dependencies: Dependencies, security: SecurityFunctions = .live) {
        self.dependencies = dependencies
        self.security = security
    }
    
    // MARK: - Functions
    
    public func data(forKey key: KeychainStorage.DataKey) throws -> Data {
        return try read(key, accessGroup: nil)
    }

    public func set(data: Data, forKey key: KeychainStorage.DataKey) throws {
        try write(data, forKey: key, accessGroup: nil)

        /// Mirror into the app group's access group, because an unscoped write which adds the item puts it only in the app's
        /// default access group - the team-prefixed one, which a change of team ID takes away. Mirroring at this level rather
        /// than at each call site is deliberate: there are three unscoped writers today and this covers future ones too
        ///
        /// A failure here must not fail the write the caller asked for. The item is still readable, and
        /// `KeychainAccessGroupMigration` re-mirrors it on the next launch
        do { try set(data: data, forKey: key, accessGroup: appGroupAccessGroup) }
        catch {
            Log.warn(.keychain, "Failed to mirror \(key.rawValue) into the app group access group: \(error)")
        }
    }
    
    public func remove(key: KeychainStorage.DataKey) throws {
        /// Unscoped, so this removes the item from every access group the app belongs to
        let status: OSStatus = security.delete(query(for: key.rawValue, accessGroup: nil))
        
        guard status == errSecSuccess else {
            throw KeychainStorageError.failure(
                code: status,
                logCategory: .keychain,
                description: "Error removing data, OSStatusCode: \(status)"
            )
        }
    }

    public func data(forKey key: KeychainStorage.DataKey, accessGroup: String) throws -> Data {
        return try read(key, accessGroup: accessGroup)
    }

    public func set(data: Data, forKey key: KeychainStorage.DataKey, accessGroup: String) throws {
        try write(data, forKey: key, accessGroup: accessGroup)
    }
    
    // MARK: - Internal Functions
    
    /// A `nil` access group searches, updates or deletes across **every** access group the app belongs to, and adds to its
    /// default one
    private func query(for account: String, accessGroup: String?) -> [String: Any] {
        var result: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account
        ]
        
        if let accessGroup: String = accessGroup {
            result[kSecAttrAccessGroup as String] = accessGroup
        }
        
        return result
    }
    
    /// Each status is taken from the call it describes, never from state shared with other calls: a concurrent operation could
    /// replace it in between, and a misattributed "not found" is what makes `getOrGenerateEncryptionKey` replace a key which
    /// still exists
    private func read(_ key: KeychainStorage.DataKey, accessGroup: String?) throws -> Data {
        var readQuery: [String: Any] = query(for: key.rawValue, accessGroup: accessGroup)
        readQuery[kSecMatchLimit as String] = kSecMatchLimitOne
        readQuery[kSecReturnData as String] = kCFBooleanTrue
        
        /// Callers act on "not found" by generating a replacement, which destroys the existing key if the read was wrong, so it is
        /// only reported once a second, independent read agrees
        var result: (status: OSStatus, data: Data?) = security.copyData(readQuery)
        
        if result.status == errSecItemNotFound {
            result = security.copyData(readQuery)
        }
        
        guard result.status == errSecSuccess, let data: Data = result.data else {
            throw KeychainStorageError.failure(
                code: result.status,
                logCategory: .keychain,
                description: "Error retrieving data\(accessGroup == nil ? "" : " for access group"), OSStatusCode: \(result.status)"
            )
        }
        
        return data
    }
    
    /// Updates in place rather than deleting and then adding: a failed add (eg. while the keychain is locked), or the process being
    /// killed between the two, would leave no item at all, and an unscoped delete removes it from every access group
    private func write(_ data: Data, forKey key: KeychainStorage.DataKey, accessGroup: String?) throws {
        let itemQuery: [String: Any] = query(for: key.rawValue, accessGroup: accessGroup)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        var status: OSStatus = security.update(itemQuery, attributes)
        
        if status == errSecItemNotFound {
            status = security.add(itemQuery.merging(attributes) { _, new in new })
            
            /// Another write can add the item between the update and the add
            if status == errSecDuplicateItem {
                status = security.update(itemQuery, attributes)
            }
        }
        
        guard status == errSecSuccess else {
            throw KeychainStorageError.failure(
                code: status,
                logCategory: .keychain,
                description: "Error setting data\(accessGroup == nil ? "" : " for access group"), OSStatusCode: \(status)"
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
                        
                        try set(data: keySpec, forKey: key)
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

// MARK: - SecurityFunctions

extension KeychainStorage {
    /// The Security framework calls `KeychainStorage` makes, replaceable so a spec can make one fail or answer differently on
    /// a second call, which the real keychain can't be made to do on demand
    struct SecurityFunctions {
        let copyData: ([String: Any]) -> (status: OSStatus, data: Data?)
        let add: ([String: Any]) -> OSStatus
        let update: ([String: Any], [String: Any]) -> OSStatus
        let delete: ([String: Any]) -> OSStatus
        
        static let live: SecurityFunctions = SecurityFunctions(
            copyData: { query in
                var result: CFTypeRef?
                let status: OSStatus = SecItemCopyMatching(query as CFDictionary, &result)
                
                return (status, result as? Data)
            },
            add: { query in SecItemAdd(query as CFDictionary, nil) },
            update: { query, attributes in SecItemUpdate(query as CFDictionary, attributes as CFDictionary) },
            delete: { query in SecItemDelete(query as CFDictionary) }
        )
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
