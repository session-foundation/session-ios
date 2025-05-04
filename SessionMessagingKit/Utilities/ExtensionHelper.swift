// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionSnodeKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let extensionHelper: SingletonConfig<ExtensionHelperType> = Dependencies.create(
        identifier: "extensionHelper",
        createInstance: { dependencies in ExtensionHelper(using: dependencies) }
    )
}

// MARK: - KeychainStorage

// stringlint:ignore_contents
public extension KeychainStorage.DataKey {
    static let extensionEncryptionKey: Self = "ExtensionEncryptionKeyKey"
}

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("ExtensionHelper", defaultLevel: .info)
}

// MARK: - ExtensionHelper

public class ExtensionHelper: ExtensionHelperType {
    private lazy var cacheDirectoryPath: String = "\(dependencies[singleton: .fileManager].appSharedDataDirectoryPath)/extensionCache"
    private lazy var dedupePath: String = "\(cacheDirectoryPath)/dedupe"
    private let encryptionKeyLength: Int = 32
    
    private let dependencies: Dependencies
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - File Management
    
    private func write(data: Data, to path: String) throws {
        /// Load in the data and `encKey` and reset the `encKey` as soon as the function ends
        guard
            var encKey: [UInt8] = (try? dependencies[singleton: .keychain]
                .getOrGenerateEncryptionKey(
                    forKey: .extensionEncryptionKey,
                    length: encryptionKeyLength,
                    cat: .cat
                )).map({ Array($0) })
        else { throw ExtensionHelperError.noEncryptionKey }
        defer { encKey.resetBytes(in: 0..<encKey.count) }
        
        /// Ensure the directory exists
        let parentDirectory: String = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .path
        try? dependencies[singleton: .fileManager].ensureDirectoryExists(at: parentDirectory)
        try? dependencies[singleton: .fileManager].protectFileOrFolder(at: parentDirectory)
        
        /// Generate the `ciphertext`
        let ciphertext: Data = try dependencies[singleton: .crypto].tryGenerate(
            .ciphertextWithXChaCha20(
                plaintext: data,
                encKey: encKey
            )
        )
        
        /// Write the data to a temporary file first, then remove any existing file and move the temporary file to the final path
        let tmpPath: String = dependencies[singleton: .fileManager].temporaryFilePath(fileExtension: nil)
        
        guard dependencies[singleton: .fileManager].createFile(atPath: tmpPath, contents: ciphertext) else {
            throw ExtensionHelperError.failedToWriteToFile
        }
        try? dependencies[singleton: .fileManager].removeItem(atPath: path)
        try dependencies[singleton: .fileManager].moveItem(atPath: tmpPath, toPath: path)
    }
    
    // MARK: - Deduping
    
    // stringlint:ignore_contents
    private func dedupeRecordPath(_ threadId: String, _ uniqueIdentifier: String) -> String? {
        guard
            let threadIdData: Data = "ConvoIdSalt-\(threadId)".data(using: .utf8),
            let uniqueIdData: Data = "UniqueIdSalt-\(uniqueIdentifier)".data(using: .utf8),
            let threadIdHash: [UInt8] = dependencies[singleton: .crypto].generate(
                .hash(message: Array(threadIdData))
            ),
            let uniqueIdHash: [UInt8] = dependencies[singleton: .crypto].generate(
                .hash(message: Array(uniqueIdData))
            )
        else { return nil }
        
        return URL(
            fileURLWithPath: [
                dedupePath,
                threadIdHash.toHexString(),
                uniqueIdHash.toHexString()
            ].joined(separator: "/")
        ).path
    }
    
    public func dedupeRecordExists(threadId: String, uniqueIdentifier: String) -> Bool {
        guard let path: String = dedupeRecordPath(threadId, uniqueIdentifier) else { return false }
        
        return dependencies[singleton: .fileManager].fileExists(atPath: path)
    }
    
    public func createDedupeRecord(threadId: String, uniqueIdentifier: String) throws {
        guard let path: String = dedupeRecordPath(threadId, uniqueIdentifier) else {
            throw ExtensionHelperError.failedToStoreDedupeRecord
        }
        
        try write(data: Data(), to: path)
    }
    
    public func removeDedupeRecord(threadId: String, uniqueIdentifier: String) throws {
        guard let path: String = dedupeRecordPath(threadId, uniqueIdentifier) else {
            throw ExtensionHelperError.failedToRemoveDedupeRecord
        }
        
        try dependencies[singleton: .fileManager].removeItem(atPath: path)
        
        /// Also remove the directory if it's empty
        let parentDirectory: String = URL(fileURLWithPath: path)
            .deletingLastPathComponent()
            .path
        
        if dependencies[singleton: .fileManager].isDirectoryEmpty(atPath: parentDirectory) {
            try? dependencies[singleton: .fileManager].removeItem(atPath: parentDirectory)
        }
    }
    
    public func deleteAllDedupeRecords() {
        try? dependencies[singleton: .fileManager].removeItem(atPath: dedupePath)
    }
}

// MARK: - ExtensionHelperError

public enum ExtensionHelperError: Error, CustomStringConvertible {
    case noEncryptionKey
    case failedToWriteToFile
    case failedToStoreDedupeRecord
    case failedToRemoveDedupeRecord
    
    // stringlint:ignore_contents
    public var description: String {
        switch self {
            case .noEncryptionKey: return "No encryption key available."
            case .failedToWriteToFile: return "Failed to write to file."
            case .failedToStoreDedupeRecord: return "Failed to store a record for message deduplication."
            case .failedToRemoveDedupeRecord: return "Failed to remove a record for message deduplication."
        }
    }
}

// MARK: - ExtensionHelperType

public protocol ExtensionHelperType {
    // MARK: - Deduping
    
    func dedupeRecordExists(threadId: String, uniqueIdentifier: String) -> Bool
    func createDedupeRecord(threadId: String, uniqueIdentifier: String) throws
    func removeDedupeRecord(threadId: String, uniqueIdentifier: String) throws
    func deleteAllDedupeRecords()
}
