// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionNetworkingKit
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class ExtensionHelperSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies(
            initialState: { dependencies in
                dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
                dependencies.forceSynchronous = true
            }
        )
        @TestState(singleton: .extensionHelper, in: dependencies) var extensionHelper: ExtensionHelper! = ExtensionHelper(using: dependencies)
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            migrations: SNMessagingKit.migrations,
            using: dependencies
        )
        @TestState(singleton: .crypto, in: dependencies) var mockCrypto: MockCrypto! = MockCrypto(
            initialSetup: { crypto in
                crypto.when { $0.generate(.hash(message: .any)) }.thenReturn([1, 2, 3])
                crypto
                    .when { $0.generate(.ciphertextWithXChaCha20(plaintext: .any, encKey: .any)) }
                    .thenReturn(Data([4, 5, 6]))
            }
        )
        @TestState(singleton: .fileManager, in: dependencies) var mockFileManager: MockFileManager! = MockFileManager(
            initialSetup: { $0.defaultInitialSetup() }
        )
        @TestState(singleton: .keychain, in: dependencies) var mockKeychain: MockKeychain! = MockKeychain(
            initialSetup: { keychain in
                keychain
                    .when {
                        try $0.getOrGenerateEncryptionKey(
                            forKey: .any,
                            length: .any,
                            cat: .any,
                            legacyKey: .any,
                            legacyService: .any
                        )
                    }
                    .thenReturn(Data([1, 2, 3]))
            }
        )
        @TestState(cache: .libSession, in: dependencies) var mockLibSessionCache: MockLibSessionCache! = MockLibSessionCache(
            initialSetup: { $0.defaultInitialSetup() }
        )
        
        @TestState(cache: .general, in: dependencies) var mockGeneralCache: MockGeneralCache! = MockGeneralCache(
            initialSetup: { cache in
                cache.when { $0.sessionId }.thenReturn(SessionId(.standard, hex: TestConstants.publicKey))
            }
        )
        @TestState var mockLogger: MockLogger! = MockLogger()
        
        // MARK: - an ExtensionHelper - File Management
        describe("an ExtensionHelper") {
            // MARK: -- can delete the entire cache
            it("can delete the entire cache") {
                extensionHelper.deleteCache()
                
                expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                    try? $0.removeItem(atPath: "/test/extensionCache")
                })
            }
            
            // MARK: -- when writing an encrypted file
            context("when writing an encrypted file") {
                // MARK: ---- ensures the write directory exists
                it("ensures the write directory exists") {
                    try? extensionHelper.createDedupeRecord(
                        threadId: "threadId",
                        uniqueIdentifier: "uniqueId"
                    )
                    
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try? $0.ensureDirectoryExists(at: "/test/extensionCache/conversations/010203/dedupe")
                    })
                }
                
                // MARK: ---- protects the write directory
                it("protects the write directory") {
                    try? extensionHelper.createDedupeRecord(
                        threadId: "threadId",
                        uniqueIdentifier: "uniqueId"
                    )
                    
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try? $0.protectFileOrFolder(at: "/test/extensionCache/conversations/010203/dedupe")
                    })
                }
                
                // MARK: ---- generates a temporary file path
                it("generates a temporary file path") {
                    try? extensionHelper.createDedupeRecord(
                        threadId: "threadId",
                        uniqueIdentifier: "uniqueId"
                    )
                    
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        $0.temporaryFilePath(fileExtension: nil)
                    })
                }
                
                // MARK: ---- writes the encrypted data to the temporary file path
                it("writes the encrypted data to the temporary file path") {
                    expect {
                        try extensionHelper.createDedupeRecord(
                            threadId: "threadId",
                            uniqueIdentifier: "uniqueId"
                        )
                    }.toNot(throwError())
                    
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try $0.write(data: Data([4, 5, 6]), toPath: "tmpFile")
                    })
                }
                
                // MARK: ---- replaces the destination path with the temporary file
                it("replaces the destination path with the temporary file") {
                    try? extensionHelper.createDedupeRecord(
                        threadId: "threadId",
                        uniqueIdentifier: "uniqueId"
                    )
                    
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        _ = try $0.replaceItem(
                            atPath: "/test/extensionCache/conversations/010203/dedupe/010203",
                            withItemAtPath: "tmpFile"
                        )
                    })
                }
                
                // MARK: ---- throws when failing to retrieve the encryption key
                it("throws when failing to retrieve the encryption key") {
                    mockKeychain
                        .when {
                            try $0.getOrGenerateEncryptionKey(
                                forKey: .any,
                                length: .any,
                                cat: .any,
                                legacyKey: .any,
                                legacyService: .any
                            )
                        }
                        .thenThrow(TestError.mock)
                    
                    expect {
                        try extensionHelper.createDedupeRecord(
                            threadId: "threadId",
                            uniqueIdentifier: "uniqueId"
                        )
                    }.to(throwError(ExtensionHelperError.noEncryptionKey))
                }
                
                // MARK: ---- throws encryption errors
                it("throws encryption errors") {
                    mockCrypto
                        .when {
                            try $0.tryGenerate(
                                .ciphertextWithXChaCha20(plaintext: .any, encKey: .any)
                            )
                        }
                        .thenThrow(TestError.mock)
                    
                    expect {
                        try extensionHelper.createDedupeRecord(
                            threadId: "threadId",
                            uniqueIdentifier: "uniqueId"
                        )
                    }.to(throwError(TestError.mock))
                }
                
                // MARK: ---- throws when it fails to write to disk
                it("throws when it fails to write to disk") {
                    mockFileManager
                        .when { try $0.write(data: .any, toPath: .any) }
                        .thenThrow(TestError.mock)
                    
                    expect {
                        try extensionHelper.createDedupeRecord(
                            threadId: "threadId",
                            uniqueIdentifier: "uniqueId"
                        )
                    }.to(throwError(ExtensionHelperError.failedToWriteToFile(TestError.mock)))
                }
                
                // MARK: ---- does not throw when attempting to remove an existing item at the destination fails
                it("does not throw when attempting to remove an existing item at the destination fails") {
                    mockFileManager
                        .when { try $0.removeItem(atPath: .any) }
                        .thenThrow(TestError.mock)
                    
                    expect {
                        try extensionHelper.createDedupeRecord(
                            threadId: "threadId",
                            uniqueIdentifier: "uniqueId"
                        )
                    }.toNot(throwError(TestError.mock))
                }
                
                // MARK: ---- throws when it fails to move the temp file to the final location
                it("throws when it fails to move the temp file to the final location") {
                    mockFileManager
                        .when { _ = try $0.replaceItem(atPath: .any, withItemAtPath: .any) }
                        .thenThrow(TestError.mock)
                    
                    expect {
                        try extensionHelper.createDedupeRecord(
                            threadId: "threadId",
                            uniqueIdentifier: "uniqueId"
                        )
                    }.to(throwError(TestError.mock))
                }
            }
        }
        
        // MARK: - an ExtensionHelper - User Metadata
        describe("an ExtensionHelper") {
            // MARK: -- when saving user metadata
            context("when saving user metadata") {
                // MARK: ---- saves the file successfully
                it("saves the file successfully") {
                    expect {
                        try extensionHelper.saveUserMetadata(
                            sessionId: SessionId(.standard, hex: TestConstants.publicKey),
                            ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
                            unreadCount: 1
                        )
                    }.toNot(throwError())
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try $0.write(data: Data(base64Encoded: "BAUG")!, toPath: "tmpFile")
                    })
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        _ = try $0.replaceItem(
                            atPath: "/test/extensionCache/metadata",
                            withItemAtPath: "tmpFile"
                        )
                    })
                }
                
                // MARK: ---- throws when failing to write the file
                it("throws when failing to write the file") {
                    mockFileManager
                        .when { _ = try $0.replaceItem(atPath: .any, withItemAtPath: .any) }
                        .thenThrow(TestError.mock)
                    
                    expect {
                        try extensionHelper.saveUserMetadata(
                            sessionId: SessionId(.standard, hex: TestConstants.publicKey),
                            ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
                            unreadCount: 1
                        )
                    }.to(throwError(TestError.mock))
                }
            }
            
            // MARK: -- when loading user metadata
            context("when loading user metadata") {
                // MARK: ---- loads the data correctly
                it("loads the data correctly") {
                    mockFileManager.when { try $0.contents(atPath: .any) }.thenReturn(Data([1, 2, 3]))
                    mockCrypto
                        .when { $0.generate(.plaintextWithXChaCha20(ciphertext: .any, encKey: .any)) }
                        .thenReturn(
                            try! JSONEncoder(using: dependencies)
                                .encode(
                                    ExtensionHelper.UserMetadata(
                                        sessionId: SessionId(.standard, hex: TestConstants.publicKey),
                                        ed25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
                                        unreadCount: 1
                                    )
                                )
                        )
                    
                    let result: ExtensionHelper.UserMetadata? = extensionHelper.loadUserMetadata()
                    
                    expect(result).toNot(beNil())
                    expect(result?.sessionId).to(equal(SessionId(.standard, hex: TestConstants.publicKey)))
                    expect(result?.ed25519SecretKey).to(equal(Array(Data(hex: TestConstants.edSecretKey))))
                    expect(result?.unreadCount).to(equal(1))
                }
                
                // MARK: ---- returns null if there is no file
                it("returns null if there is no file") {
                    mockFileManager.when { try $0.contents(atPath: .any) }.thenReturn(nil)
                    
                    let result: ExtensionHelper.UserMetadata? = extensionHelper.loadUserMetadata()
                    
                    expect(result).to(beNil())
                }
                
                // MARK: ---- returns null if it fails to decrypt the file
                it("returns null if it fails to decrypt the file") {
                    mockFileManager.when { try $0.contents(atPath: .any) }.thenReturn(Data([1, 2, 3]))
                    mockCrypto
                        .when { $0.generate(.plaintextWithXChaCha20(ciphertext: .any, encKey: .any)) }
                        .thenReturn(nil)
                    
                    let result: ExtensionHelper.UserMetadata? = extensionHelper.loadUserMetadata()
                    
                    expect(result).to(beNil())
                }
                
                // MARK: ---- returns null if it fails to decode the data
                it("returns null if it fails to decode the data") {
                    mockFileManager.when { try $0.contents(atPath: .any) }.thenReturn(Data([1, 2, 3]))
                    mockCrypto
                        .when { $0.generate(.plaintextWithXChaCha20(ciphertext: .any, encKey: .any)) }
                        .thenReturn(Data([1, 2, 3]))
                    
                    let result: ExtensionHelper.UserMetadata? = extensionHelper.loadUserMetadata()
                    
                    expect(result).to(beNil())
                }
            }
        }
        
        // MARK: - an ExtensionHelper - Deduping
        describe("an ExtensionHelper") {
            // MARK: -- when checking whether it has a dedupe record since the last clear
            context("when checking whether it has a dedupe record since the last clear") {
                // MARK: ---- returns true when at least one record exists that is newer than the last cleared timestamp
                it("returns true when at least one record exists that is newer than the last cleared timestamp") {
                    mockCrypto.when { $0.generate(.hash(message: .any)) }.thenReturn([1, 2, 3])
                    mockFileManager.when { try $0.contentsOfDirectory(atPath: .any) }.thenReturn(["Test1234"])
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: "/test/extensionCache/conversations/010203/dedupe/010203") }
                        .thenReturn([FileAttributeKey.creationDate: Date(timeIntervalSince1970: 1234567800)])
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: "/test/extensionCache/conversations/010203/dedupe/Test1234") }
                        .thenReturn([FileAttributeKey.creationDate: Date(timeIntervalSince1970: 1234567900)])
                    
                    expect(extensionHelper.hasDedupeRecordSinceLastCleared(threadId: "threadId")).to(beTrue())
                }
                
                // MARK: ---- returns false when it cannot get the conversation path
                it("returns false when it cannot get the conversation path") {
                    mockCrypto.when { $0.generate(.hash(message: .any)) }.thenReturn(nil)
                    
                    expect(extensionHelper.hasDedupeRecordSinceLastCleared(threadId: "threadId")).to(beFalse())
                }
                
                // MARK: ---- returns false when a record does not exist
                it("returns false when a record does not exist") {
                    mockCrypto.when { $0.generate(.hash(message: .any)) }.thenReturn([1, 2, 3])
                    mockFileManager.when { try $0.contentsOfDirectory(atPath: .any) }.thenReturn([])
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: "/test/extensionCache/conversations/010203/dedupe/010203") }
                        .thenReturn([FileAttributeKey.creationDate: Date(timeIntervalSince1970: 1234567800)])
                    
                    expect(extensionHelper.hasDedupeRecordSinceLastCleared(threadId: "threadId")).to(beFalse())
                }
                
                // MARK: ---- returns false when a record exists but is too old
                it("returns false when a record exists but is too old") {
                    mockCrypto.when { $0.generate(.hash(message: .any)) }.thenReturn([1, 2, 3])
                    mockFileManager.when { try $0.contentsOfDirectory(atPath: .any) }.thenReturn(["Test1234"])
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: "/test/extensionCache/conversations/010203/dedupe/010203") }
                        .thenReturn([FileAttributeKey.modificationDate: Date(timeIntervalSince1970: 1234567900)])
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: "/test/extensionCache/conversations/010203/dedupe/Test1234") }
                        .thenReturn([FileAttributeKey.creationDate: Date(timeIntervalSince1970: 1234567800)])
                    
                    expect(extensionHelper.hasDedupeRecordSinceLastCleared(threadId: "threadId")).to(beFalse())
                }
                
                // MARK: ---- ignores the lastCleared file when comparing dedupe records
                it("ignores the lastCleared file when comparing dedupe records") {
                    mockCrypto.when { $0.generate(.hash(message: .any)) }.thenReturn([1, 2, 3])
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    mockFileManager
                        .when { try $0.contentsOfDirectory(atPath: .any) }
                        .thenReturn(["010203"])
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: .any) }
                        .thenReturn([FileAttributeKey.creationDate: Date(timeIntervalSince1970: 1234567900)])
                    
                    expect(extensionHelper.hasDedupeRecordSinceLastCleared(threadId: "threadId")).to(beFalse())
                }
                
                // MARK: ---- returns true when at least one record exists and there is no last cleared timestamp
                it("returns true when at least one record exists and there is no last cleared timestamp") {
                    mockCrypto.when { $0.generate(.hash(message: .any)) }.thenReturn([1, 2, 3])
                    mockFileManager.when { try $0.contentsOfDirectory(atPath: .any) }.thenReturn(["Test1234"])
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: "/test/extensionCache/conversations/010203/dedupe/010203") }
                        .thenReturn([:])
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: "/test/extensionCache/conversations/010203/dedupe/Test1234") }
                        .thenReturn([FileAttributeKey.creationDate: Date(timeIntervalSince1970: 1234567900)])
                    
                    expect(extensionHelper.hasDedupeRecordSinceLastCleared(threadId: "threadId")).to(beTrue())
                }
            }
            
            // MARK: -- when checking for dedupe records
            context("when checking for dedupe records") {
                // MARK: ---- returns true when a record exists
                it("returns true when a record exists") {
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    
                    expect(extensionHelper.dedupeRecordExists(
                        threadId: "threadId",
                        uniqueIdentifier: "uniqueId"
                    )).to(beTrue())
                }
                
                // MARK: ---- returns false when a record does not exist
                it("returns false when a record does not exist") {
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(false)
                    
                    expect(extensionHelper.dedupeRecordExists(
                        threadId: "threadId",
                        uniqueIdentifier: "uniqueId"
                    )).to(beFalse())
                }
                
                // MARK: ---- returns false when failing to generate a hash
                it("returns false when failing to generate a hash") {
                    mockCrypto.when { $0.generate(.hash(message: .any)) }.thenReturn(nil)
                    
                    expect(extensionHelper.dedupeRecordExists(
                        threadId: "threadId",
                        uniqueIdentifier: "uniqueId"
                    )).to(beFalse())
                }
            }
            
            // MARK: -- when creating dedupe records
            context("when creating dedupe records") {
                // MARK: ---- writes the file successfully
                it("writes the file successfully") {
                    try? extensionHelper.createDedupeRecord(
                        threadId: "threadId",
                        uniqueIdentifier: "uniqueId"
                    )
                    
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        _ = try $0.replaceItem(
                            atPath: "/test/extensionCache/conversations/010203/dedupe/010203",
                            withItemAtPath: "tmpFile"
                        )
                    })
                }
                
                // MARK: ---- throws when failing to generate a hash
                it("throws when failing to generate a hash") {
                    mockCrypto.when { $0.generate(.hash(message: .any)) }.thenReturn(nil)
                    
                    expect {
                        try extensionHelper.createDedupeRecord(
                            threadId: "threadId",
                            uniqueIdentifier: "uniqueId"
                        )
                    }.to(throwError(ExtensionHelperError.failedToStoreDedupeRecord))
                }
                
                // MARK: ---- throws when failing to write the file
                it("throws when failing to write the file") {
                    mockFileManager
                        .when { _ = try $0.replaceItem(atPath: .any, withItemAtPath: .any) }
                        .thenThrow(TestError.mock)
                    
                    expect {
                        try extensionHelper.createDedupeRecord(
                            threadId: "threadId",
                            uniqueIdentifier: "uniqueId"
                        )
                    }.to(throwError(TestError.mock))
                }
            }
            
            // MARK: -- when removing dedupe records
            context("when removing dedupe records") {
                // MARK: ---- removes the file successfully
                it("removes the file successfully") {
                    try? extensionHelper.removeDedupeRecord(
                        threadId: "threadId",
                        uniqueIdentifier: "uniqueId"
                    )
                    
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try? $0.removeItem(atPath: "/test/extensionCache/conversations/010203/dedupe/010203")
                    })
                }
                
                // MARK: ---- removes the parent directory if it is empty
                it("removes the parent directory if it is empty") {
                    try? extensionHelper.removeDedupeRecord(
                        threadId: "threadId",
                        uniqueIdentifier: "uniqueId"
                    )
                    
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try? $0.removeItem(atPath: "/test/extensionCache/conversations/010203/dedupe")
                    })
                }
                
                // MARK: ---- leaves the parent directory if not empty
                it("leaves the parent directory if not empty") {
                    mockFileManager.when { $0.isDirectoryEmpty(atPath: .any) }.thenReturn(false)
                    
                    try? extensionHelper.removeDedupeRecord(
                        threadId: "threadId",
                        uniqueIdentifier: "uniqueId"
                    )
                    
                    expect(mockFileManager).toNot(call(.exactly(times: 1), matchingParameters: .all) {
                        try? $0.removeItem(atPath: "/test/extensionCache/conversations/010203/dedupe")
                    })
                }
                
                // MARK: ---- does nothing when failing to generate a hash
                it("does nothing when failing to generate a hash") {
                    mockCrypto.when { $0.generate(.hash(message: .any)) }.thenReturn(nil)
                    
                    expect {
                        try extensionHelper.removeDedupeRecord(
                            threadId: "threadId",
                            uniqueIdentifier: "uniqueId"
                        )
                    }.toNot(throwError(ExtensionHelperError.failedToStoreDedupeRecord))
                    expect(mockFileManager).toNot(call(.exactly(times: 1), matchingParameters: .all) {
                        try? $0.removeItem(atPath: "/test/extensionCache/conversations/010203/dedupe/010203")
                    })
                }
                
                // MARK: ---- throws when failing to remove the file
                it("throws when failing to remove the file") {
                    mockFileManager.when { try $0.removeItem(atPath: .any) }.thenThrow(TestError.mock)
                    
                    expect {
                        try extensionHelper.removeDedupeRecord(
                            threadId: "threadId",
                            uniqueIdentifier: "uniqueId"
                        )
                    }.to(throwError(TestError.mock))
                }
            }
            
            // MARK: -- when upserting a last cleared record
            context("when upserting a last cleared record") {
                // MARK: ---- creates the file successfully
                it("creates the file successfully") {
                    mockCrypto
                        .when { $0.generate(.ciphertextWithXChaCha20(plaintext: .any, encKey: .any)) }
                        .thenReturn(Data())
                    
                    expect {
                        try extensionHelper.upsertLastClearedRecord(threadId: "threadId")
                    }.toNot(throwError())
                    
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try $0.write(data: Data(), toPath: "tmpFile")
                    })
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        _ = try $0.replaceItem(
                            atPath: "/test/extensionCache/conversations/010203/dedupe/010203",
                            withItemAtPath: "tmpFile"
                        )
                    })
                }
                
                // MARK: ---- throws when failing to generate a hash
                it("throws when failing to generate a hash") {
                    mockCrypto.when { $0.generate(.hash(message: .any)) }.thenReturn(nil)
                    
                    expect {
                        try extensionHelper.upsertLastClearedRecord(threadId: "threadId")
                    }.to(throwError(ExtensionHelperError.failedToUpdateLastClearedRecord))
                    expect(mockFileManager).toNot(call(.exactly(times: 1), matchingParameters: .all) {
                        try? $0.removeItem(atPath: "/test/extensionCache/conversations/010203/dedupe/010203")
                    })
                    expect(mockFileManager).toNot(call { try $0.write(data: .any, toPath: .any) })
                    expect(mockFileManager).toNot(call { try $0.replaceItem(atPath: .any, withItemAtPath: .any) })
                }
                
                // MARK: ---- throws when failing to write the file
                it("throws when failing to write the file") {
                    mockFileManager
                        .when { _ = try $0.replaceItem(atPath: .any, withItemAtPath: .any) }
                        .thenThrow(TestError.mock)
                    
                    expect {
                        try extensionHelper.upsertLastClearedRecord(threadId: "threadId")
                    }.to(throwError(TestError.mock))
                }
            }
        }
        
        // MARK: - an ExtensionHelper - Config Dumps
        describe("an ExtensionHelper") {
            beforeEach {
                Log.setup(with: mockLogger)
            }
            
            // MARK: -- when retrieving the last updated timestamp
            context("when retrieving the last updated timestamp") {
                // MARK: ---- returns the timestamp
                it("returns the timestamp") {
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: .any) }
                        .thenReturn([.modificationDate: Date(timeIntervalSince1970: 1234567890)])
                    
                    expect(extensionHelper.lastUpdatedTimestamp(
                        for: SessionId(.standard, hex: TestConstants.publicKey),
                        variant: .userProfile
                    )).to(equal(1234567890))
                }
                
                // MARK: ---- returns zero when it fails to generate a hash
                it("returns zero when it fails to generate a hash") {
                    mockCrypto.when { $0.generate(.hash(message: .any)) }.thenReturn(nil)
                    
                    expect(extensionHelper.lastUpdatedTimestamp(
                        for: SessionId(.standard, hex: TestConstants.publicKey),
                        variant: .userProfile
                    )).to(equal(0))
                }
                
                // MARK: ---- throws when failing to retrieve file metadata
                it("throws when failing to retrieve file metadata") {
                    mockFileManager.when { try $0.attributesOfItem(atPath: .any) }.thenReturn(nil)
                    
                    expect(extensionHelper.lastUpdatedTimestamp(
                        for: SessionId(.standard, hex: TestConstants.publicKey),
                        variant: .userProfile
                    )).to(equal(0))
                }
            }
            
            // MARK: -- when replicating a config dump
            context("when replicating a config dump") {
                // MARK: ---- replicates successfully
                it("replicates successfully") {
                    extensionHelper.replicate(
                        dump: ConfigDump(
                            variant: .userProfile,
                            sessionId: "05\(TestConstants.publicKey)",
                            data: Data([1, 2, 3]),
                            timestampMs: 1234567890
                        ),
                        replaceExisting: true
                    )
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try $0.write(data: Data(base64Encoded: "BAUG")!, toPath: "tmpFile")
                    })
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        _ = try $0.replaceItem(
                            atPath: "/test/extensionCache/conversations/010203/dumps/010203",
                            withItemAtPath: "tmpFile"
                        )
                    })
                }
                
                // MARK: ---- does nothing when given a null dump
                it("does nothing when given a null dump") {
                    extensionHelper.replicate(dump: nil, replaceExisting: true)
                    
                    expect(mockFileManager).toNot(call { try $0.write(data: .any, toPath: .any) })
                    expect(mockFileManager).toNot(call { try $0.replaceItem(atPath: .any, withItemAtPath: .any) })
                }
                
                // MARK: ---- does nothing when failing to generate a hash
                it("does nothing when failing to generate a hash") {
                    mockCrypto.when { $0.generate(.hash(message: .any)) }.thenReturn(nil)
                    
                    extensionHelper.replicate(
                        dump: ConfigDump(
                            variant: .userProfile,
                            sessionId: "05\(TestConstants.publicKey)",
                            data: Data([1, 2, 3]),
                            timestampMs: 1234567890
                        ),
                        replaceExisting: true
                    )
                    
                    expect(mockFileManager).toNot(call { try $0.write(data: .any, toPath: .any) })
                    expect(mockFileManager).toNot(call { try $0.replaceItem(atPath: .any, withItemAtPath: .any) })
                }
                
                // MARK: ---- does nothing a file already exists and we do not want to replace it
                it("does nothing a file already exists and we do not want to replace it") {
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    
                    extensionHelper.replicate(
                        dump: ConfigDump(
                            variant: .userProfile,
                            sessionId: "05\(TestConstants.publicKey)",
                            data: Data([1, 2, 3]),
                            timestampMs: 1234567890
                        ),
                        replaceExisting: false
                    )
                    
                    expect(mockFileManager).toNot(call { try $0.write(data: .any, toPath: .any) })
                    expect(mockFileManager).toNot(call { try $0.replaceItem(atPath: .any, withItemAtPath: .any) })
                }
                
                // MARK: ---- logs an error when failing to write the file
                it("logs an error when failing to write the file") {
                    mockFileManager
                        .when { _ = try $0.replaceItem(atPath: .any, withItemAtPath: .any) }
                        .thenThrow(TestError.mock)
                    
                    extensionHelper.replicate(
                        dump: ConfigDump(
                            variant: .userProfile,
                            sessionId: "05\(TestConstants.publicKey)",
                            data: Data([1, 2, 3]),
                            timestampMs: 1234567890
                        ),
                        replaceExisting: true
                    )
                    
                    await expect { await mockLogger.logs }.toEventually(equal([
                        MockLogger.LogOutput(
                            level: .error,
                            categories: [
                                Log.Category.create(
                                    "ExtensionHelper",
                                    group: nil,
                                    customSuffix: "",
                                    defaultLevel: .info
                                )
                            ],
                            message: "Failed to replicate userProfile dump for 05\(TestConstants.publicKey) due to error: mock.",
                            file: "SessionMessagingKit/ExtensionHelper.swift",
                            function: "replicate(dump:replaceExisting:)"
                        )
                    ]))
                }
            }
            
            // MARK: -- when replicating all config dumps
            context("when replicating all config dumps") {
                struct DumpReplicationValues {
                    let key: String
                    let sessionId: String?
                    let variant: ConfigDump.Variant?
                    let hashValue: [UInt8]
                    let plaintext: Data
                    let ciphertext: Data
                    
                    init(_ key: String, _ value: [UInt8]) {
                        self.key = key
                        self.sessionId = nil
                        self.variant = nil
                        self.hashValue = value
                        self.plaintext = Data(value + value)
                        self.ciphertext = Data(value)
                    }
                    
                    init(_ variant: ConfigDump.Variant, _ value: [UInt8]) {
                        self.key = "DumpSalt-\(variant)"
                        self.sessionId = (ConfigDump.Variant.userVariants.contains(variant) ?
                            "05\(TestConstants.publicKey)" :
                            "03\(TestConstants.publicKey)"
                        )
                        self.variant = variant
                        self.hashValue = value
                        self.plaintext = Data(value + value)
                        self.ciphertext = Data(value)
                    }
                }
                
                @TestState var mockValues: [DumpReplicationValues]! = [
                    DumpReplicationValues("ConvoIdSalt-05\(TestConstants.publicKey)", [1, 2, 3]),
                    DumpReplicationValues(ConfigDump.Variant.userProfile, [2, 3, 4]),
                    DumpReplicationValues(ConfigDump.Variant.contacts, [3, 4, 5]),
                    DumpReplicationValues(ConfigDump.Variant.convoInfoVolatile, [4, 5, 6]),
                    DumpReplicationValues(ConfigDump.Variant.userGroups, [5, 6, 7]),
                    DumpReplicationValues(ConfigDump.Variant.local, [6, 7, 8]),
                    DumpReplicationValues("ConvoIdSalt-03\(TestConstants.publicKey)", [9, 8, 7]),
                    DumpReplicationValues(ConfigDump.Variant.groupInfo, [8, 7, 6]),
                    DumpReplicationValues(ConfigDump.Variant.groupMembers, [7, 6, 5]),
                    DumpReplicationValues(ConfigDump.Variant.groupKeys, [6, 5, 4])
                ]
                
                beforeEach {
                    mockFileManager.when { try $0.contents(atPath: .any) }.thenReturn(nil)
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: .any) }
                        .thenReturn([.modificationDate: Date(timeIntervalSince1970: 1234567800)])
                    mockCrypto
                        .when { $0.generate(.plaintextWithXChaCha20(ciphertext: .any, encKey: .any)) }
                        .thenReturn(Data([1, 2, 3]))
                    mockValues.forEach { value in
                        mockCrypto
                            .when { $0.generate(.hash(message: Array(value.key.data(using: .utf8)!))) }
                            .thenReturn(value.hashValue)
                        mockCrypto
                            .when { $0.generate(.ciphertextWithXChaCha20(plaintext: value.plaintext, encKey: .any)) }
                            .thenReturn(value.ciphertext)
                    }
                    
                    mockStorage.write { db in
                        try mockValues.forEach { values in
                            guard
                                let sessionId: String = values.sessionId,
                                let variant: ConfigDump.Variant = values.variant
                            else { return }
                            
                            try ConfigDump(
                                variant: variant,
                                sessionId: sessionId,
                                data: values.plaintext,
                                timestampMs: 1234567890
                            ).insert(db)
                        }
                    }
                }
                
                // MARK: ---- replicates successfully
                it("replicates successfully") {
                    extensionHelper.replicateAllConfigDumpsIfNeeded(
                        userSessionId: SessionId(.standard, hex: "05\(TestConstants.publicKey)"),
                        allDumpSessionIds: [SessionId(.standard, hex: "05\(TestConstants.publicKey)")]
                    )
                    
                    let allCreateFileCalls: [CallDetails]? = await expect(mockFileManager
                        .allCalls { try $0.write(data: .any, toPath: .any) })
                        .toEventually(haveCount(5))
                        .retrieveValue()
                    let allMoveFileCalls: [CallDetails]? = await expect(mockFileManager
                        .allCalls { try $0.replaceItem(atPath: .any, withItemAtPath: .any) })
                        .toEventually(haveCount(5))
                        .retrieveValue()
                    
                    let emptyOptions: String = "Optional(__C.NSFileManagerItemReplacementOptions(rawValue: 0))"
                    expect((allCreateFileCalls?.map { $0.parameterSummary }).map { Set($0) })
                        .to(equal([
                            "[Data(base64Encoded: AgME), tmpFile]",
                            "[Data(base64Encoded: AwQF), tmpFile]",
                            "[Data(base64Encoded: BAUG), tmpFile]",
                            "[Data(base64Encoded: BQYH), tmpFile]",
                            "[Data(base64Encoded: BgcI), tmpFile]"
                        ]))
                    expect((allMoveFileCalls?.map { $0.parameterSummary }).map { Set($0) })
                        .to(equal([
                            "[/test/extensionCache/conversations/010203/dumps/020304, tmpFile, nil, \(emptyOptions)]",
                            "[/test/extensionCache/conversations/010203/dumps/030405, tmpFile, nil, \(emptyOptions)]",
                            "[/test/extensionCache/conversations/010203/dumps/040506, tmpFile, nil, \(emptyOptions)]",
                            "[/test/extensionCache/conversations/010203/dumps/050607, tmpFile, nil, \(emptyOptions)]",
                            "[/test/extensionCache/conversations/010203/dumps/060708, tmpFile, nil, \(emptyOptions)]"
                        ]))
                }
                
                // MARK: ---- replicates all user configs if they cannot be found
                it("replicates all user configs if they cannot be found") {
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(false)
                    
                    extensionHelper.replicateAllConfigDumpsIfNeeded(
                        userSessionId: SessionId(.standard, hex: "05\(TestConstants.publicKey)"),
                        allDumpSessionIds: [SessionId(.standard, hex: "05\(TestConstants.publicKey)")]
                    )
                    
                    let allCreateFileCalls: [CallDetails]? = await expect(mockFileManager
                        .allCalls { try $0.write(data: .any, toPath: .any) })
                        .toEventually(haveCount(5))
                        .retrieveValue()
                    let allMoveFileCalls: [CallDetails]? = await expect(mockFileManager
                        .allCalls { try $0.replaceItem(atPath: .any, withItemAtPath: .any) })
                        .toEventually(haveCount(5))
                        .retrieveValue()
                    
                    let emptyOptions: String = "Optional(__C.NSFileManagerItemReplacementOptions(rawValue: 0))"
                    expect((allCreateFileCalls?.map { $0.parameterSummary }).map { Set($0) })
                        .to(equal([
                            "[Data(base64Encoded: AgME), tmpFile]",
                            "[Data(base64Encoded: AwQF), tmpFile]",
                            "[Data(base64Encoded: BAUG), tmpFile]",
                            "[Data(base64Encoded: BQYH), tmpFile]",
                            "[Data(base64Encoded: BgcI), tmpFile]"
                        ]))
                    expect((allMoveFileCalls?.map { $0.parameterSummary }).map { Set($0) })
                        .to(equal([
                            "[/test/extensionCache/conversations/010203/dumps/020304, tmpFile, nil, \(emptyOptions)]",
                            "[/test/extensionCache/conversations/010203/dumps/030405, tmpFile, nil, \(emptyOptions)]",
                            "[/test/extensionCache/conversations/010203/dumps/040506, tmpFile, nil, \(emptyOptions)]",
                            "[/test/extensionCache/conversations/010203/dumps/050607, tmpFile, nil, \(emptyOptions)]",
                            "[/test/extensionCache/conversations/010203/dumps/060708, tmpFile, nil, \(emptyOptions)]"
                        ]))
                }
                
                // MARK: ---- replicates all configs for a group if one cannot be found
                it("replicates all configs for a group if one cannot be found") {
                    mockValues.forEach { value in
                        guard let variant: ConfigDump.Variant = value.variant else { return }
                        
                        let isGroupVariant: Bool = ConfigDump.Variant.groupVariants.contains(variant)
                        let convo: String = (isGroupVariant ? "090807" : "010203")
                        let dump: String = value.hashValue.toHexString()
                        mockFileManager
                            .when {
                                $0.fileExists(
                                    atPath: "/test/extensionCache/conversations/\(convo)/dumps/\(dump)"
                                )
                            }
                            .thenReturn(!isGroupVariant)
                    }
                    
                    extensionHelper.replicateAllConfigDumpsIfNeeded(
                        userSessionId: SessionId(.standard, hex: "05\(TestConstants.publicKey)"),
                        allDumpSessionIds: [
                            SessionId(.standard, hex: "05\(TestConstants.publicKey)"),
                            SessionId(.group, hex: "03\(TestConstants.publicKey)"),
                        ]
                    )
                    
                    let allCreateFileCalls: [CallDetails]? = await expect(mockFileManager
                        .allCalls { try $0.write(data: .any, toPath: .any) })
                        .toEventually(haveCount(3))
                        .retrieveValue()
                    let allMoveFileCalls: [CallDetails]? = await expect(mockFileManager
                        .allCalls { try $0.replaceItem(atPath: .any, withItemAtPath: .any) })
                        .toEventually(haveCount(3))
                        .retrieveValue()
                
                    let emptyOptions: String = "Optional(__C.NSFileManagerItemReplacementOptions(rawValue: 0))"
                    expect((allCreateFileCalls?.map { $0.parameterSummary }).map { Set($0) })
                        .to(equal([
                            "[Data(base64Encoded: BgUE), tmpFile]",
                            "[Data(base64Encoded: BwYF), tmpFile]",
                            "[Data(base64Encoded: CAcG), tmpFile]"
                        ]))
                    expect((allMoveFileCalls?.map { $0.parameterSummary }).map { Set($0) })
                        .to(equal([
                            "[/test/extensionCache/conversations/090807/dumps/060504, tmpFile, nil, \(emptyOptions)]",
                            "[/test/extensionCache/conversations/090807/dumps/070605, tmpFile, nil, \(emptyOptions)]",
                            "[/test/extensionCache/conversations/090807/dumps/080706, tmpFile, nil, \(emptyOptions)]"
                        ]))
                }
                
                // MARK: ---- does nothing when failing to generate a hash
                it("does nothing when failing to generate a hash") {
                    mockValues.forEach { value in
                        mockCrypto
                            .when { $0.generate(.hash(message: Array(value.key.data(using: .utf8)!))) }
                            .thenReturn(nil)
                    }
                    
                    extensionHelper.replicateAllConfigDumpsIfNeeded(
                        userSessionId: SessionId(.standard, hex: "05\(TestConstants.publicKey)"),
                        allDumpSessionIds: [SessionId(.standard, hex: "05\(TestConstants.publicKey)")]
                    )
                    
                    expect(mockFileManager).toNot(call { try $0.write(data: .any, toPath: .any) })
                    expect(mockFileManager).toNot(call { try $0.replaceItem(atPath: .any, withItemAtPath: .any) })
                }
                
                // MARK: ---- does nothing if valid dumps already exist
                it("does nothing if valid dumps already exist") {
                    mockFileManager.when { try $0.contents(atPath: .any) }.thenReturn(Data([1, 2, 3]))
                    mockCrypto
                        .when { $0.generate(.plaintextWithXChaCha20(ciphertext: .any, encKey: .any)) }
                        .thenReturn(Data([1, 2, 3]))
                    
                    extensionHelper.replicateAllConfigDumpsIfNeeded(
                        userSessionId: SessionId(.standard, hex: "05\(TestConstants.publicKey)"),
                        allDumpSessionIds: [SessionId(.standard, hex: "05\(TestConstants.publicKey)")]
                    )
                    
                    expect(mockFileManager).toNot(call { try $0.write(data: .any, toPath: .any) })
                    expect(mockFileManager).toNot(call { try $0.replaceItem(atPath: .any, withItemAtPath: .any) })
                }
                
                // MARK: ---- does nothing if there are no dumps in the database
                it("does nothing if there are no dumps in the database") {
                    mockStorage.write { db in try ConfigDump.deleteAll(db) }
                    
                    extensionHelper.replicateAllConfigDumpsIfNeeded(
                        userSessionId: SessionId(.standard, hex: "05\(TestConstants.publicKey)"),
                        allDumpSessionIds: []
                    )
                    
                    expect(mockFileManager).toNot(call { try $0.write(data: .any, toPath: .any) })
                    expect(mockFileManager).toNot(call { try $0.replaceItem(atPath: .any, withItemAtPath: .any) })
                }
                
                // MARK: ---- does nothing if the existing replicated dump was newer than the fetched one
                it("does nothing if the existing replicated dump was newer than the fetched one") {
                    dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: .any) }
                        .thenReturn([.modificationDate: Date(timeIntervalSince1970: 1234567891)])
                    
                    extensionHelper.replicateAllConfigDumpsIfNeeded(
                        userSessionId: SessionId(.standard, hex: "05\(TestConstants.publicKey)"),
                        allDumpSessionIds: [SessionId(.standard, hex: "05\(TestConstants.publicKey)")]
                    )
                    
                    expect(mockFileManager).toNot(call { try $0.write(data: .any, toPath: .any) })
                    expect(mockFileManager).toNot(call { try $0.replaceItem(atPath: .any, withItemAtPath: .any) })
                }
                
                // MARK: ---- does nothing if it fails to replicate
                it("does nothing if it fails to replicate") {
                    mockCrypto
                        .when { $0.generate(.ciphertextWithXChaCha20(plaintext: Data([2, 3, 4]), encKey: .any)) }
                        .thenThrow(TestError.mock)
                    mockCrypto
                        .when { $0.generate(.ciphertextWithXChaCha20(plaintext: Data([5, 6, 7]), encKey: .any)) }
                        .thenThrow(TestError.mock)
                    
                    extensionHelper.replicateAllConfigDumpsIfNeeded(
                        userSessionId: SessionId(.standard, hex: "05\(TestConstants.publicKey)"),
                        allDumpSessionIds: [SessionId(.standard, hex: "05\(TestConstants.publicKey)")]
                    )
                    
                    expect(mockFileManager).toNot(call { try $0.write(data: .any, toPath: .any) })
                    expect(mockFileManager).toNot(call { try $0.replaceItem(atPath: .any, withItemAtPath: .any) })
                }
            }

            // MARK: -- when refreshing the dump modified date
            context("when refreshing the dump modified date") {
                beforeEach {
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                }
                
                // MARK: ---- updates the modified date
                it("updates the modified date") {
                    extensionHelper.refreshDumpModifiedDate(
                        sessionId: SessionId(.standard, hex: "05\(TestConstants.publicKey)"),
                        variant: .userProfile
                    )
                    
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try $0.setAttributes(
                            [.modificationDate: Date(timeIntervalSince1970: 1234567890)],
                            ofItemAtPath: "/test/extensionCache/conversations/010203/dumps/010203"
                        )
                    })
                }
                
                // MARK: ---- does nothing when it fails to generate a hash
                it("does nothing when it fails to generate a hash") {
                    mockCrypto.when { $0.generate(.hash(message: .any)) }.thenReturn(nil)
                    
                    extensionHelper.refreshDumpModifiedDate(
                        sessionId: SessionId(.standard, hex: "05\(TestConstants.publicKey)"),
                        variant: .userProfile
                    )
                    
                    expect(mockFileManager).toNot(call { try $0.setAttributes(.any, ofItemAtPath: .any) })
                }
                
                // MARK: ---- does nothing if the file does not exist
                it("does nothing if the file does not exist") {
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(false)
                    
                    extensionHelper.refreshDumpModifiedDate(
                        sessionId: SessionId(.standard, hex: "05\(TestConstants.publicKey)"),
                        variant: .userProfile
                    )
                    
                    expect(mockFileManager).toNot(call { try $0.setAttributes(.any, ofItemAtPath: .any) })
                }
            }
            
            // MARK: -- when loading user configs
            context("when loading user configs") {
                beforeEach {
                    mockCrypto
                        .when { $0.generate(.plaintextWithXChaCha20(ciphertext: .any, encKey: .any)) }
                        .thenReturn(Data([1, 2, 3]))
                }
                
                // MARK: ---- sets the configs for each of the user variants
                it("sets the configs for each of the user variants") {
                    let ptr: UnsafeMutablePointer<config_object> = UnsafeMutablePointer<config_object>.allocate(capacity: 1)
                    let configs: [LibSession.Config] = [
                        .userProfile(ptr), .userGroups(ptr), .contacts(ptr), .convoInfoVolatile(ptr)
                    ]
                    configs.forEach { config in
                        mockLibSessionCache
                            .when {
                                try $0.loadState(
                                    for: config.variant,
                                    sessionId: .any,
                                    userEd25519SecretKey: .any,
                                    groupEd25519SecretKey: .any,
                                    cachedData: .any
                                )
                            }
                            .thenReturn(config)
                    }
                    
                    extensionHelper.loadUserConfigState(
                        into: mockLibSessionCache,
                        userSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                        userEd25519SecretKey: Array(Data(hex: TestConstants.edSecretKey))
                    )
                    expect(mockLibSessionCache).to(call(.exactly(times: 1), matchingParameters: .all) {
                        $0.setConfig(
                            for: .userProfile,
                            sessionId: SessionId(.standard, hex: TestConstants.publicKey),
                            to: .userProfile(ptr)
                        )
                    })
                    expect(mockLibSessionCache).to(call(.exactly(times: 1), matchingParameters: .all) {
                        $0.setConfig(
                            for: .userGroups,
                            sessionId: SessionId(.standard, hex: TestConstants.publicKey),
                            to: .userGroups(ptr)
                        )
                    })
                    expect(mockLibSessionCache).to(call(.exactly(times: 1), matchingParameters: .all) {
                        $0.setConfig(
                            for: .contacts,
                            sessionId: SessionId(.standard, hex: TestConstants.publicKey),
                            to: .contacts(ptr)
                        )
                    })
                    expect(mockLibSessionCache).to(call(.exactly(times: 1), matchingParameters: .all) {
                        $0.setConfig(
                            for: .convoInfoVolatile,
                            sessionId: SessionId(.standard, hex: TestConstants.publicKey),
                            to: .convoInfoVolatile(ptr)
                        )
                    })
                    
                    ptr.deallocate()
                }
                
                // MARK: ---- loads the default states when failing to load config data
                it("loads the default states when failing to load config data") {
                    mockLibSessionCache
                        .when {
                            try $0.loadState(
                                for: .any,
                                sessionId: .any,
                                userEd25519SecretKey: .any,
                                groupEd25519SecretKey: .any,
                                cachedData: .any
                            )
                        }
                        .thenReturn(nil)
                    
                    extensionHelper.loadUserConfigState(
                        into: mockLibSessionCache,
                        userSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                        userEd25519SecretKey: Array(Data(hex: TestConstants.edSecretKey))
                    )
                    expect(mockLibSessionCache).to(call(.exactly(times: 1), matchingParameters: .all) {
                        $0.loadDefaultStateFor(
                            variant: .userProfile,
                            sessionId: SessionId(.standard, hex: TestConstants.publicKey),
                            userEd25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
                            groupEd25519SecretKey: nil
                        )
                    })
                    expect(mockLibSessionCache).to(call(.exactly(times: 1), matchingParameters: .all) {
                        $0.loadDefaultStateFor(
                            variant: .userGroups,
                            sessionId: SessionId(.standard, hex: TestConstants.publicKey),
                            userEd25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
                            groupEd25519SecretKey: nil
                        )
                    })
                    expect(mockLibSessionCache).to(call(.exactly(times: 1), matchingParameters: .all) {
                        $0.loadDefaultStateFor(
                            variant: .contacts,
                            sessionId: SessionId(.standard, hex: TestConstants.publicKey),
                            userEd25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
                            groupEd25519SecretKey: nil
                        )
                    })
                    expect(mockLibSessionCache).to(call(.exactly(times: 1), matchingParameters: .all) {
                        $0.loadDefaultStateFor(
                            variant: .convoInfoVolatile,
                            sessionId: SessionId(.standard, hex: TestConstants.publicKey),
                            userEd25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
                            groupEd25519SecretKey: nil
                        )
                    })
                }
            }
            
            // MARK: -- when loading group configs
            context("when loading group configs") {
                beforeEach {
                    mockCrypto
                        .when { $0.generate(.plaintextWithXChaCha20(ciphertext: .any, encKey: .any)) }
                        .thenReturn(Data([1, 2, 3]))
                }
                
                // MARK: ---- sets the configs for each of the group variants
                it("sets the configs for each of the group variants") {
                    let ptr: UnsafeMutablePointer<config_object> = UnsafeMutablePointer<config_object>.allocate(capacity: 1)
                    let keysPtr: UnsafeMutablePointer<config_group_keys> = UnsafeMutablePointer<config_group_keys>.allocate(capacity: 1)
                    let configs: [LibSession.Config] = [
                        .groupKeys(keysPtr, info: ptr, members: ptr), .groupMembers(ptr), .groupInfo(ptr)
                    ]
                    configs.forEach { config in
                        mockLibSessionCache
                            .when {
                                try $0.loadState(
                                    for: config.variant,
                                    sessionId: .any,
                                    userEd25519SecretKey: .any,
                                    groupEd25519SecretKey: .any,
                                    cachedData: .any
                                )
                            }
                            .thenReturn(config)
                    }
                    
                    expect {
                        try extensionHelper.loadGroupConfigStateIfNeeded(
                            into: mockLibSessionCache,
                            swarmPublicKey: "03\(TestConstants.publicKey)",
                            userEd25519SecretKey: [1, 2, 3]
                        )
                    }.toNot(throwError())
                    expect(mockLibSessionCache).to(call(.exactly(times: 1), matchingParameters: .all) {
                        $0.setConfig(
                            for: .groupKeys,
                            sessionId: SessionId(.group, hex: TestConstants.publicKey),
                            to: .groupKeys(keysPtr, info: ptr, members: ptr)
                        )
                    })
                    expect(mockLibSessionCache).to(call(.exactly(times: 1), matchingParameters: .all) {
                        $0.setConfig(
                            for: .groupMembers,
                            sessionId: SessionId(.group, hex: TestConstants.publicKey),
                            to: .groupMembers(ptr)
                        )
                    })
                    expect(mockLibSessionCache).to(call(.exactly(times: 1), matchingParameters: .all) {
                        $0.setConfig(
                            for: .groupInfo,
                            sessionId: SessionId(.group, hex: TestConstants.publicKey),
                            to: .groupInfo(ptr)
                        )
                    })
                    
                    keysPtr.deallocate()
                    ptr.deallocate()
                }
                
                // MARK: ---- returns correct config load results
                it("returns correct config load results") {
                    let ptr: UnsafeMutablePointer<config_object> = UnsafeMutablePointer<config_object>.allocate(capacity: 1)
                    let keysPtr: UnsafeMutablePointer<config_group_keys> = UnsafeMutablePointer<config_group_keys>.allocate(capacity: 1)
                    let configs: [LibSession.Config] = [
                        .groupKeys(keysPtr, info: ptr, members: ptr), .groupInfo(ptr)
                    ]
                    
                    mockCrypto.removeMocksFor { $0.generate(.hash(message: .any)) }
                    configs.forEach { config in
                        mockLibSessionCache
                            .when {
                                try $0.loadState(
                                    for: config.variant,
                                    sessionId: .any,
                                    userEd25519SecretKey: .any,
                                    groupEd25519SecretKey: .any,
                                    cachedData: .any
                                )
                            }
                            .thenReturn(config)
                        mockCrypto
                            .when { $0.generate(.hash(message: Array("DumpSalt-\(config.variant)".utf8))) }
                            .thenReturn([0, 1, 2])
                    }
                    mockCrypto
                        .when { $0.generate(.hash(message: Array("ConvoIdSalt-03\(TestConstants.publicKey)".utf8))) }
                        .thenReturn([4, 5, 6])
                    mockCrypto
                        .when {
                            $0.generate(.hash(message: Array("DumpSalt-\(ConfigDump.Variant.groupMembers)".utf8)))
                        }
                        .thenReturn(nil)
                    
                    var result: [ConfigDump.Variant: Bool] = [:]
                    expect {
                        result = try extensionHelper.loadGroupConfigStateIfNeeded(
                            into: mockLibSessionCache,
                            swarmPublicKey: "03\(TestConstants.publicKey)",
                            userEd25519SecretKey: [1, 2, 3]
                        )
                    }.toNot(throwError())
                    expect(result).to(equal([
                        ConfigDump.Variant.groupKeys: true,
                        ConfigDump.Variant.groupMembers: false,
                        ConfigDump.Variant.groupInfo: true
                    ]))
                    
                    keysPtr.deallocate()
                    ptr.deallocate()
                }
                
                // MARK: ---- does nothing if it cannot get a dump for the config
                it("does nothing if it cannot get a dump for the config") {
                    mockFileManager.when { try $0.contents(atPath: .any) }.thenReturn(nil)
                    
                    expect {
                        try extensionHelper.loadGroupConfigStateIfNeeded(
                            into: mockLibSessionCache,
                            swarmPublicKey: "03\(TestConstants.publicKey)",
                            userEd25519SecretKey: [1, 2, 3]
                        )
                    }.toNot(throwError())
                    expect(mockLibSessionCache).toNot(call {
                        $0.setConfig(for: .any, sessionId: .any, to: .any)
                    })
                }
                
                // MARK: ---- does nothing if the provided public key is not for a group
                it("does nothing if the provided public key is not for a group") {
                    expect {
                        try extensionHelper.loadGroupConfigStateIfNeeded(
                            into: mockLibSessionCache,
                            swarmPublicKey: "05\(TestConstants.publicKey)",
                            userEd25519SecretKey: [1, 2, 3]
                        )
                    }.toNot(throwError())
                    expect(mockLibSessionCache).toNot(call {
                        $0.setConfig(for: .any, sessionId: .any, to: .any)
                    })
                }
            }
        }
        
        // MARK: - an ExtensionHelper - Notification Settings
        describe("an ExtensionHelper") {
            struct NotificationSettings: Codable {
                let threadId: String
                let mentionsOnly: Bool
                let mutedUntil: TimeInterval?
            }
            
            // MARK: -- when replicating notification settings
            context("when replicating notification settings") {
                beforeEach {
                    mockFileManager.when { try $0.contents(atPath: .any) }.thenReturn(nil)
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: .any) }
                        .thenReturn([.modificationDate: Date(timeIntervalSince1970: 1234567800)])
                    mockCrypto
                        .when { $0.generate(.hash(message: .any)) }
                        .thenReturn([0, 1, 2])
                    mockCrypto
                        .when { $0.generate(.plaintextWithXChaCha20(ciphertext: .any, encKey: .any)) }
                        .thenReturn(Data([1, 2, 3]))
                }
                
                // MARK: ---- replicates successfully
                it("replicates successfully") {
                    try? extensionHelper.replicate(
                        settings: [
                            "Test1": Preferences.NotificationSettings(
                                previewType: .nameAndPreview,
                                sound: .note,
                                mentionsOnly: false,
                                mutedUntil: nil
                            )
                        ],
                        replaceExisting: true
                    )
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try $0.write(data: Data(base64Encoded: "BAUG")!, toPath: "tmpFile")
                    })
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        _ = try $0.replaceItem(
                            atPath: "/test/extensionCache/notificationSettings",
                            withItemAtPath: "tmpFile"
                        )
                    })
                }
                
                // MARK: ---- excludes values with default settings
                it("excludes values with default settings") {
                    let expectedResult: [NotificationSettings] = [
                        NotificationSettings(
                            threadId: "Test2",
                            mentionsOnly: false,
                            mutedUntil: 1234
                        )
                    ]
                    
                    try? extensionHelper.replicate(
                        settings: [
                            "Test1": Preferences.NotificationSettings(
                                previewType: .nameAndPreview,
                                sound: .note,
                                mentionsOnly: false,
                                mutedUntil: nil
                            ),
                            "Test2": Preferences.NotificationSettings(
                                previewType: .nameAndPreview,
                                sound: .note,
                                mentionsOnly: false,
                                mutedUntil: 1234
                            )
                        ],
                        replaceExisting: true
                    )
                    expect(mockCrypto).to(call(.exactly(times: 1), matchingParameters: .all) {
                        $0.generate(
                            .ciphertextWithXChaCha20(
                                plaintext: try JSONEncoder(using: dependencies)
                                    .encode(expectedResult),
                                encKey: [1, 2, 3]
                            )
                        )
                    })
                }
                
                // MARK: ---- does nothing if the settings already exist and we do not want to replace existing
                it("does nothing if the settings already exist and we do not want to replace existing") {
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    
                    try? extensionHelper.replicate(
                        settings: [
                            "Test1": Preferences.NotificationSettings(
                                previewType: .nameAndPreview,
                                sound: .note,
                                mentionsOnly: false,
                                mutedUntil: nil
                            )
                        ],
                        replaceExisting: false
                    )
                    
                    expect(mockFileManager).toNot(call { try $0.write(data: .any, toPath: .any) })
                    expect(mockFileManager).toNot(call { try $0.replaceItem(atPath: .any, withItemAtPath: .any) })
                }
                
                // MARK: ---- does nothing if it fails to replicate
                it("does nothing if it fails to replicate") {
                    mockCrypto
                        .when { $0.generate(.ciphertextWithXChaCha20(plaintext: Data([2, 3, 4]), encKey: .any)) }
                        .thenThrow(TestError.mock)
                    mockCrypto
                        .when { $0.generate(.ciphertextWithXChaCha20(plaintext: Data([5, 6, 7]), encKey: .any)) }
                        .thenThrow(TestError.mock)
                    
                    try? extensionHelper.replicate(
                        settings: [
                            "Test1": Preferences.NotificationSettings(
                                previewType: .nameAndPreview,
                                sound: .note,
                                mentionsOnly: false,
                                mutedUntil: nil
                            )
                        ],
                        replaceExisting: true
                    )
                    
                    expect(mockFileManager).toNot(call { try $0.write(data: .any, toPath: .any) })
                    expect(mockFileManager).toNot(call { try $0.replaceItem(atPath: .any, withItemAtPath: .any) })
                }
            }
            
            // MARK: -- when loading notification settings
            context("when loading notification settings") {
                // MARK: ---- loads the data correctly
                it("loads the data correctly") {
                    mockFileManager.when { try $0.contents(atPath: .any) }.thenReturn(Data([1, 2, 3]))
                    mockCrypto
                        .when { $0.generate(.plaintextWithXChaCha20(ciphertext: .any, encKey: .any)) }
                        .thenReturn(
                            try! JSONEncoder(using: dependencies)
                                .encode(
                                    [
                                        NotificationSettings(
                                            threadId: "Test1",
                                            mentionsOnly: false,
                                            mutedUntil: nil
                                        ),
                                        NotificationSettings(
                                            threadId: "Test2",
                                            mentionsOnly: true,
                                            mutedUntil: 12345
                                        )
                                    ]
                                )
                        )
                    
                    let result: [String: Preferences.NotificationSettings]? = extensionHelper.loadNotificationSettings(
                        previewType: .nameAndPreview,
                        sound: .note
                    )
                    
                    try require(result).toNot(beNil())
                    try require(result?["Test1"]).toNot(beNil())
                    try require(result?["Test2"]).toNot(beNil())
                    expect(result?["Test1"]?.previewType).to(equal(.nameAndPreview))
                    expect(result?["Test1"]?.sound).to(equal(.note))
                    expect(result?["Test1"]?.mentionsOnly).to(beFalse())
                    expect(result?["Test1"]?.mutedUntil).to(beNil())
                    expect(result?["Test2"]?.previewType).to(equal(.nameAndPreview))
                    expect(result?["Test2"]?.sound).to(equal(.note))
                    expect(result?["Test2"]?.mentionsOnly).to(beTrue())
                    expect(result?["Test2"]?.mutedUntil).to(equal(12345))
                }
                
                // MARK: ---- returns null if there is no file
                it("returns null if there is no file") {
                    mockFileManager.when { try $0.contents(atPath: .any) }.thenReturn(nil)
                    
                    let result: [String: Preferences.NotificationSettings]? = extensionHelper.loadNotificationSettings(
                        previewType: .nameAndPreview,
                        sound: .note
                    )
                    
                    expect(result).to(beNil())
                }
                
                // MARK: ---- returns null if it fails to decrypt the file
                it("returns null if it fails to decrypt the file") {
                    mockFileManager.when { try $0.contents(atPath: .any) }.thenReturn(Data([1, 2, 3]))
                    mockCrypto
                        .when { $0.generate(.plaintextWithXChaCha20(ciphertext: .any, encKey: .any)) }
                        .thenReturn(nil)
                    
                    let result: [String: Preferences.NotificationSettings]? = extensionHelper.loadNotificationSettings(
                        previewType: .nameAndPreview,
                        sound: .note
                    )
                    
                    expect(result).to(beNil())
                }
                
                // MARK: ---- returns null if it fails to decode the data
                it("returns null if it fails to decode the data") {
                    mockFileManager.when { try $0.contents(atPath: .any) }.thenReturn(Data([1, 2, 3]))
                    mockCrypto
                        .when { $0.generate(.plaintextWithXChaCha20(ciphertext: .any, encKey: .any)) }
                        .thenReturn(Data([1, 2, 3]))
                    
                    let result: [String: Preferences.NotificationSettings]? = extensionHelper.loadNotificationSettings(
                        previewType: .nameAndPreview,
                        sound: .note
                    )
                    
                    expect(result).to(beNil())
                }
            }
        }
        
        // MARK: - an ExtensionHelper - Messages
        describe("an ExtensionHelper") {
            beforeEach {
                Log.setup(with: mockLogger)
            }
            
            // MARK: -- when retrieving the unread message count
            context("when retrieving the unread message count") {
                // MARK: ---- returns the count
                it("returns the count") {
                    mockFileManager
                        .when { try $0.contentsOfDirectory(atPath: "/test/extensionCache/conversations") }
                        .thenReturn(["a"])
                    mockFileManager
                        .when {
                            try $0.contentsOfDirectory(
                                atPath: "/test/extensionCache/conversations/a/unread"
                            )
                        }
                        .thenReturn(["b", "c", "d", "e", "f"])
                    mockCrypto
                        .when { $0.generate(.hash(message: Array("a".utf8) + Array("messageRequest".utf8))) }
                        .thenReturn([3, 4, 5])
                    let validPaths: [String] = [
                        "/test/extensionCache/conversations/a/unread",
                        "/test/extensionCache/conversations/a/unread/b",
                        "/test/extensionCache/conversations/a/unread/c",
                        "/test/extensionCache/conversations/a/unread/d",
                        "/test/extensionCache/conversations/a/unread/e",
                        "/test/extensionCache/conversations/a/unread/f"
                    ]
                    validPaths.forEach { path in
                        mockFileManager.when { $0.fileExists(atPath: path) }.thenReturn(true)
                    }
                    mockFileManager
                        .when { $0.fileExists(atPath: "/test/extensionCache/conversations/a/unread/030405") }
                        .thenReturn(false)
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: .any) }
                        .thenReturn([FileAttributeKey.creationDate: Date(timeIntervalSince1970: 1234567900)])
                    
                    expect(extensionHelper.unreadMessageCount()).to(equal(5))
                }
                
                // MARK: ---- adds the total from multiple conversations
                it("adds the total from multiple conversations") {
                    mockFileManager
                        .when { try $0.contentsOfDirectory(atPath: "/test/extensionCache/conversations") }
                        .thenReturn(["a", "b"])
                    mockFileManager
                        .when {
                            try $0.contentsOfDirectory(
                                atPath: "/test/extensionCache/conversations/a/unread"
                            )
                        }
                        .thenReturn(["c", "d", "e"])
                    mockFileManager
                        .when {
                            try $0.contentsOfDirectory(
                                atPath: "/test/extensionCache/conversations/b/unread"
                            )
                        }
                        .thenReturn(["f", "g", "h"])
                    let validPaths: [String] = [
                        "/test/extensionCache/conversations/a/unread",
                        "/test/extensionCache/conversations/a/unread/c",
                        "/test/extensionCache/conversations/a/unread/d",
                        "/test/extensionCache/conversations/a/unread/e",
                        "/test/extensionCache/conversations/b/unread",
                        "/test/extensionCache/conversations/b/unread/f",
                        "/test/extensionCache/conversations/b/unread/g",
                        "/test/extensionCache/conversations/b/unread/h"
                    ]
                    validPaths.forEach { path in
                        mockFileManager.when { $0.fileExists(atPath: path) }.thenReturn(true)
                    }
                    mockFileManager
                        .when { $0.fileExists(atPath: "/test/extensionCache/conversations/a/unread/030405") }
                        .thenReturn(false)
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: .any) }
                        .thenReturn([FileAttributeKey.creationDate: Date(timeIntervalSince1970: 1234567900)])
                    
                    expect(extensionHelper.unreadMessageCount()).to(equal(6))
                }
                
                // MARK: ---- only counts message requests as a single item even with multiple unread messages
                it("only counts message requests as a single item even with multiple unread messages") {
                    mockFileManager.removeMocksFor { try $0.contentsOfDirectory(atPath: .any) }
                    mockFileManager
                        .when { try $0.contentsOfDirectory(atPath: "/test/extensionCache/conversations") }
                        .thenReturn(["a"])
                    mockFileManager
                        .when {
                            try $0.contentsOfDirectory(
                                atPath: "/test/extensionCache/conversations/a/unread"
                            )
                        }
                        .thenReturn(["030405", "b", "c", "d"])
                    mockFileManager
                        .when {
                            try $0.contentsOfDirectory(
                                atPath: "/test/extensionCache/conversations/a/dedupe"
                            )
                        }
                        .thenReturn(["b1", "b1-legacy", "c1", "c1-legacy", "d1", "d1-legacy"])
                    mockCrypto
                        .when { $0.generate(.hash(message: Array("a".utf8) + Array("messageRequest".utf8))) }
                        .thenReturn([3, 4, 5])
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    let validPaths: [String] = [
                        "/test/extensionCache/conversations/a/unread/b",
                        "/test/extensionCache/conversations/a/unread/c",
                        "/test/extensionCache/conversations/a/unread/d",
                        "/test/extensionCache/conversations/a/dedupe/b1",
                        "/test/extensionCache/conversations/a/dedupe/b1-legacy",
                        "/test/extensionCache/conversations/a/dedupe/c1",
                        "/test/extensionCache/conversations/a/dedupe/c1-legacy",
                        "/test/extensionCache/conversations/a/dedupe/d1",
                        "/test/extensionCache/conversations/a/dedupe/d1-legacy"
                    ]
                    validPaths.forEach { path in
                        mockFileManager
                            .when { try $0.attributesOfItem(atPath: path) }
                            .thenReturn([FileAttributeKey.creationDate: Date(timeIntervalSince1970: 1234567900)])
                    }
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: "/test/extensionCache/conversations/a/unread/030405") }
                        .thenReturn([FileAttributeKey.creationDate: Date(timeIntervalSince1970: 1234560000)])
                    
                    expect(extensionHelper.unreadMessageCount()).to(equal(1))
                }
                
                // MARK: ---- ignores hidden files in the conversations directory
                it("ignores hidden files in the conversations directory") {
                    mockFileManager
                        .when { try $0.contentsOfDirectory(atPath: "/test/extensionCache/conversations") }
                        .thenReturn([".test", "a"])
                    mockFileManager
                        .when {
                            try $0.contentsOfDirectory(
                                atPath: "/test/extensionCache/conversations/a/unread"
                            )
                        }
                        .thenReturn(["b", "c", "d", "e", "f"])
                    let validPaths: [String] = [
                        "/test/extensionCache/conversations/a/unread",
                        "/test/extensionCache/conversations/a/unread/b",
                        "/test/extensionCache/conversations/a/unread/c",
                        "/test/extensionCache/conversations/a/unread/d",
                        "/test/extensionCache/conversations/a/unread/e",
                        "/test/extensionCache/conversations/a/unread/f",
                        "/test/extensionCache/conversations/a/unread/g"
                    ]
                    validPaths.forEach { path in
                        mockFileManager.when { $0.fileExists(atPath: path) }.thenReturn(true)
                    }
                    mockFileManager
                        .when { $0.fileExists(atPath: "/test/extensionCache/conversations/a/unread/030405") }
                        .thenReturn(false)
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: .any) }
                        .thenReturn([FileAttributeKey.creationDate: Date(timeIntervalSince1970: 1234567900)])
                    
                    expect(extensionHelper.unreadMessageCount()).to(equal(5))
                }
                
                // MARK: ---- ignores hidden files in the unread directory
                it("ignores hidden files in the unread directory") {
                    mockFileManager
                        .when { try $0.contentsOfDirectory(atPath: "/test/extensionCache/conversations") }
                        .thenReturn(["a"])
                    mockFileManager
                        .when {
                            try $0.contentsOfDirectory(
                                atPath: "/test/extensionCache/conversations/a/unread"
                            )
                        }
                        .thenReturn([".test", "b", "c", "d", "e", "f"])
                    let validPaths: [String] = [
                        "/test/extensionCache/conversations/a/unread",
                        "/test/extensionCache/conversations/a/unread/b",
                        "/test/extensionCache/conversations/a/unread/c",
                        "/test/extensionCache/conversations/a/unread/d",
                        "/test/extensionCache/conversations/a/unread/e",
                        "/test/extensionCache/conversations/a/unread/f",
                        "/test/extensionCache/conversations/a/unread/g"
                    ]
                    validPaths.forEach { path in
                        mockFileManager.when { $0.fileExists(atPath: path) }.thenReturn(true)
                    }
                    mockFileManager
                        .when { $0.fileExists(atPath: "/test/extensionCache/conversations/a/unread/030405") }
                        .thenReturn(false)
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: .any) }
                        .thenReturn([FileAttributeKey.creationDate: Date(timeIntervalSince1970: 1234567890)])
                    
                    expect(extensionHelper.unreadMessageCount()).to(equal(5))
                }
                
                // MARK: ---- ignores conversations without an unread directory
                it("ignores conversations without an unread directory") {
                    mockFileManager
                        .when { try $0.contentsOfDirectory(atPath: "/test/extensionCache/conversations") }
                        .thenReturn(["a", "b"])
                    mockFileManager
                        .when {
                            try $0.contentsOfDirectory(
                                atPath: "/test/extensionCache/conversations/a/unread"
                            )
                        }
                        .thenReturn(["c", "d", "e"])
                    mockFileManager
                        .when {
                            try $0.contentsOfDirectory(
                                atPath: "/test/extensionCache/conversations/b/unread"
                            )
                        }
                        .thenReturn(["f", "g", "h"])
                    mockFileManager
                        .when { $0.fileExists(atPath: "/test/extensionCache/conversations/a/unread") }
                        .thenReturn(true)
                    mockFileManager
                        .when { $0.fileExists(atPath: "/test/extensionCache/conversations/b/unread") }
                        .thenReturn(false)
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: .any) }
                        .thenReturn([FileAttributeKey.creationDate: Date(timeIntervalSince1970: 1234567900)])
                    
                    expect(extensionHelper.unreadMessageCount()).to(equal(3))
                }
                
                // MARK: ---- ignores message request conversations if the user has seen the message requests stub
                it("ignores message request conversations if the user has seen the message requests stub") {
                    mockFileManager
                        .when { try $0.contentsOfDirectory(atPath: "/test/extensionCache/conversations") }
                        .thenReturn(["a"])
                    mockFileManager
                        .when {
                            try $0.contentsOfDirectory(
                                atPath: "/test/extensionCache/conversations/a/unread"
                            )
                        }
                        .thenReturn(["b", "c", "d", "e", "f"])
                    mockCrypto
                        .when { $0.generate(.hash(message: Array("a".utf8) + Array("messageRequest".utf8))) }
                        .thenReturn([3, 4, 5])
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: "/test/extensionCache/conversations/a/unread/b") }
                        .thenReturn([FileAttributeKey.creationDate: Date(timeIntervalSince1970: 1234567600)])
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: "/test/extensionCache/conversations/a/unread/c") }
                        .thenReturn([FileAttributeKey.creationDate: Date(timeIntervalSince1970: 1234567700)])
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: "/test/extensionCache/conversations/a/unread/d") }
                        .thenReturn([FileAttributeKey.creationDate: Date(timeIntervalSince1970: 1234567800)])
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: "/test/extensionCache/conversations/a/unread/e") }
                        .thenReturn([FileAttributeKey.creationDate: Date(timeIntervalSince1970: 1234567900)])
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: "/test/extensionCache/conversations/a/unread/f") }
                        .thenReturn([FileAttributeKey.creationDate: Date(timeIntervalSince1970: 1234568000)])
                    mockFileManager
                        .when { try $0.attributesOfItem(atPath: "/test/extensionCache/conversations/a/unread/030405") }
                        .thenReturn([FileAttributeKey.creationDate: Date(timeIntervalSince1970: 1234567900)])
                    
                    expect(extensionHelper.unreadMessageCount()).to(equal(0))
                }
                
                // MARK: ---- returns null if retrieving the conversation hashes throws
                it("returns null if retrieving the conversation hashes throws") {
                    mockFileManager
                        .when { try $0.contentsOfDirectory(atPath: .any) }
                        .thenThrow(TestError.mock)
                    
                    expect(extensionHelper.unreadMessageCount()).to(beNil())
                }
                
                // MARK: ---- returns null if retrieving the conversation hashes throws
                it("returns null if retrieving the conversation hashes throws") {
                    mockFileManager.removeMocksFor { try $0.contentsOfDirectory(atPath: .any) }
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    mockFileManager
                        .when { try $0.contentsOfDirectory(atPath: "/test/extensionCache/conversations") }
                        .thenReturn(["a"])
                    mockFileManager
                        .when {
                            try $0.contentsOfDirectory(
                                atPath: "/test/extensionCache/conversations/a/unread"
                            )
                        }
                        .thenThrow(TestError.mock)
                    
                    expect(extensionHelper.unreadMessageCount()).to(beNil())
                }
            }
            
            // MARK: -- when saving a message
            context("when saving a message") {
                // MARK: ---- saves the message correctly
                it("saves the message correctly") {
                    expect {
                        try extensionHelper.saveMessage(
                            SnodeReceivedMessage(
                                snode: nil,
                                publicKey: "05\(TestConstants.publicKey)",
                                namespace: .default,
                                rawMessage: GetMessagesResponse.RawMessage(
                                    base64EncodedDataString: "TestData",
                                    expirationMs: nil,
                                    hash: "TestHash",
                                    timestampMs: 1234567890
                                )
                            ),
                            threadId: "05\(TestConstants.publicKey)",
                            isUnread: false,
                            isMessageRequest: false
                        )
                    }.toNot(throwError())
                }
                
                // MARK: ---- saves config messages to the correct path
                it("saves config messages to the correct path") {
                    expect {
                        try extensionHelper.saveMessage(
                            SnodeReceivedMessage(
                                snode: nil,
                                publicKey: "05\(TestConstants.publicKey)",
                                namespace: .configUserProfile,
                                rawMessage: GetMessagesResponse.RawMessage(
                                    base64EncodedDataString: "TestData",
                                    expirationMs: nil,
                                    hash: "TestHash",
                                    timestampMs: 1234567890
                                )
                            ),
                            threadId: "05\(TestConstants.publicKey)",
                            isUnread: false,
                            isMessageRequest: false
                        )
                    }.toNot(throwError())
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        _ = try $0.replaceItem(
                            atPath: "/test/extensionCache/conversations/010203/config/010203",
                            withItemAtPath: "tmpFile"
                        )
                    })
                }
                
                // MARK: ---- saves unread standard messages to the correct path
                it("saves unread standard messages to the correct path") {
                    expect {
                        try extensionHelper.saveMessage(
                            SnodeReceivedMessage(
                                snode: nil,
                                publicKey: "05\(TestConstants.publicKey)",
                                namespace: .default,
                                rawMessage: GetMessagesResponse.RawMessage(
                                    base64EncodedDataString: "TestData",
                                    expirationMs: nil,
                                    hash: "TestHash",
                                    timestampMs: 1234567890
                                )
                            ),
                            threadId: "05\(TestConstants.publicKey)",
                            isUnread: true,
                            isMessageRequest: false
                        )
                    }.toNot(throwError())
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        _ = try $0.replaceItem(
                            atPath: "/test/extensionCache/conversations/010203/unread/010203",
                            withItemAtPath: "tmpFile"
                        )
                    })
                }
                
                // MARK: ---- writes the message request stub file for unread message request messages
                it("writes the message request stub file for unread message request messages") {
                    mockCrypto.removeMocksFor { $0.generate(.hash(message: .any)) }
                    mockCrypto
                        .when { $0.generate(.hash(message: Array("ConvoIdSalt-05\(TestConstants.publicKey)".utf8))) }
                        .thenReturn([1, 2, 3])
                    mockCrypto
                        .when { $0.generate(.hash(message: Array("UnreadMessageSalt-TestHash".utf8))) }
                        .thenReturn([2, 3, 4])
                    mockCrypto
                        .when { $0.generate(.hash(message: [1, 2, 3] + Array("messageRequest".utf8))) }
                        .thenReturn([3, 4, 5])
                    
                    expect {
                        try extensionHelper.saveMessage(
                            SnodeReceivedMessage(
                                snode: nil,
                                publicKey: "05\(TestConstants.publicKey)",
                                namespace: .default,
                                rawMessage: GetMessagesResponse.RawMessage(
                                    base64EncodedDataString: "TestData",
                                    expirationMs: nil,
                                    hash: "TestHash",
                                    timestampMs: 1234567890
                                )
                            ),
                            threadId: "05\(TestConstants.publicKey)",
                            isUnread: true,
                            isMessageRequest: true
                        )
                    }.toNot(throwError())
                    
                    let emptyOptions: String = "Optional(__C.NSFileManagerItemReplacementOptions(rawValue: 0))"
                    expect(mockFileManager
                        .allCalls { try $0.replaceItem(atPath: .any, withItemAtPath: .any) }?
                        .map { $0.parameterSummary }
                    )
                    .to(equal([
                        "[/test/extensionCache/conversations/010203/unread/030405, tmpFile, nil, \(emptyOptions)]",
                        "[/test/extensionCache/conversations/010203/unread/020304, tmpFile, nil, \(emptyOptions)]"
                    ]))
                }
                
                // MARK: ---- saves read standard messages to the correct path
                it("saves read standard messages to the correct path") {
                    expect {
                        try extensionHelper.saveMessage(
                            SnodeReceivedMessage(
                                snode: nil,
                                publicKey: "05\(TestConstants.publicKey)",
                                namespace: .default,
                                rawMessage: GetMessagesResponse.RawMessage(
                                    base64EncodedDataString: "TestData",
                                    expirationMs: nil,
                                    hash: "TestHash",
                                    timestampMs: 1234567890
                                )
                            ),
                            threadId: "05\(TestConstants.publicKey)",
                            isUnread: false,
                            isMessageRequest: false
                        )
                    }.toNot(throwError())
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try $0.replaceItem(
                            atPath: "/test/extensionCache/conversations/010203/read/010203",
                            withItemAtPath: "tmpFile"
                        )
                    })
                }
                
                // MARK: ---- does nothing when failing to generate a hash
                it("does nothing when failing to generate a hash") {
                    mockCrypto.when { $0.generate(.hash(message: .any)) }.thenReturn(nil)
                    
                    expect {
                        try extensionHelper.saveMessage(
                            SnodeReceivedMessage(
                                snode: nil,
                                publicKey: "05\(TestConstants.publicKey)",
                                namespace: .default,
                                rawMessage: GetMessagesResponse.RawMessage(
                                    base64EncodedDataString: "TestData",
                                    expirationMs: nil,
                                    hash: "TestHash",
                                    timestampMs: 1234567890
                                )
                            ),
                            threadId: "05\(TestConstants.publicKey)",
                            isUnread: false,
                            isMessageRequest: false
                        )
                    }.toNot(throwError())
                    expect(mockFileManager).toNot(call { try $0.replaceItem(atPath: .any, withItemAtPath: .any) })
                }
                
                // MARK: ---- throws when failing to write the file
                it("throws when failing to write the file") {
                    mockFileManager
                        .when { _ = try $0.replaceItem(atPath: .any, withItemAtPath: .any) }
                        .thenThrow(TestError.mock)
                    
                    expect {
                        try extensionHelper.saveMessage(
                            SnodeReceivedMessage(
                                snode: nil,
                                publicKey: "05\(TestConstants.publicKey)",
                                namespace: .default,
                                rawMessage: GetMessagesResponse.RawMessage(
                                    base64EncodedDataString: "TestData",
                                    expirationMs: nil,
                                    hash: "TestHash",
                                    timestampMs: 1234567890
                                )
                            ),
                            threadId: "05\(TestConstants.publicKey)",
                            isUnread: false,
                            isMessageRequest: false
                        )
                    }.to(throwError(TestError.mock))
                }
            }
            
            // MARK: -- when waiting for messages to be loaded
            context("when waiting for messages to be loaded") {
                // MARK: ---- stops waiting once messages are loaded
                it("stops waiting once messages are loaded") {
                    Task {
                        try? await Task.sleep(for: .milliseconds(10))
                        try? await extensionHelper.loadMessages()
                    }
                    await expect {
                        await extensionHelper.waitUntilMessagesAreLoaded(timeout: .milliseconds(150))
                    }.to(beTrue())
                }
                
                // MARK: ---- times out if it takes longer than the timeout specified
                it("times out if it takes longer than the timeout specified") {
                    await expect {
                        await extensionHelper.waitUntilMessagesAreLoaded(timeout: .milliseconds(50))
                    }.to(beFalse())
                }
                
                // MARK: ---- does not wait if messages have already been loaded
                it("does not wait if messages have already been loaded") {
                    await expect { try await extensionHelper.loadMessages() }.toNot(throwError())
                    await expect {
                        await extensionHelper.waitUntilMessagesAreLoaded(timeout: .milliseconds(100))
                    }.to(beTrue())
                }
                
                // MARK: ---- waits if messages have already been loaded but we indicate we will load them again
                it("waits if messages have already been loaded but we indicate we will load them again") {
                    await expect { try await extensionHelper.loadMessages() }.toNot(throwError())
                    
                    extensionHelper.willLoadMessages()
                    await expect {
                        await extensionHelper.waitUntilMessagesAreLoaded(timeout: .milliseconds(50))
                    }.to(beFalse())
                }
            }
            
            // MARK: -- when loading messages
            context("when loading messages") {
                @TestState var mockValues: [String: String]! = [
                    "/test/extensionCache/conversations": "a",
                    "/test/extensionCache/conversations/a/config": "b",
                    "/test/extensionCache/conversations/a/read": "c",
                    "/test/extensionCache/conversations/a/unread": "d",
                    "/test/extensionCache/conversations/010203/config": "d",
                    "/test/extensionCache/conversations/010203/read": "e",
                    "/test/extensionCache/conversations/010203/unread": "f",
                    "/test/extensionCache/conversations/0000550000/config": "g",
                    "/test/extensionCache/conversations/0000550000/read": "h",
                    "/test/extensionCache/conversations/0000550000/unread": "i"
                ]
                
                beforeEach {
                    mockValues.forEach { key, value in
                        mockFileManager
                            .when { try $0.contentsOfDirectory(atPath: key) }
                            .thenReturn([value])
                    }
                    mockCrypto
                        .when {
                            $0.generate(.hash(
                                message: Array("ConvoIdSalt-05\(TestConstants.publicKey)".data(using: .utf8)!)
                            ))
                        }
                        .thenReturn([1, 2, 3])
                    mockFileManager.when { try $0.contents(atPath: .any) }.thenReturn(Data([1, 2, 3]))
                    mockCrypto
                        .when { $0.generate(.plaintextWithXChaCha20(ciphertext: .any, encKey: .any)) }
                        .thenReturn(
                            try! JSONEncoder(using: dependencies)
                                .encode(
                                    SnodeReceivedMessage(
                                        snode: nil,
                                        publicKey: "05\(TestConstants.publicKey)",
                                        namespace: .default,
                                        rawMessage: GetMessagesResponse.RawMessage(
                                            base64EncodedDataString: try! MessageWrapper.wrap(
                                                type: .sessionMessage,
                                                timestampMs: 1234567890,
                                                content: Data([1, 2, 3])
                                            ).base64EncodedString(),
                                            expirationMs: nil,
                                            hash: "TestHash",
                                            timestampMs: 1234567890
                                        )
                                    )
                                )
                        )
                    
                    let content = SNProtoContent.builder()
                    let dataMessage = SNProtoDataMessage.builder()
                    dataMessage.setBody("Test")
                    content.setDataMessage(try! dataMessage.build())
                    mockCrypto
                        .when { $0.generate(.plaintextWithSessionProtocol(ciphertext: .any)) }
                        .thenReturn((try! content.build().serializedData(), "05\(TestConstants.publicKey)"))
                }
                
                // MARK: ---- successfully loads messages
                it("successfully loads messages") {
                    await expect { try await extensionHelper.loadMessages() }.toNot(throwError())
                    
                    let interactions: [Interaction]? = mockStorage.read { try Interaction.fetchAll($0) }
                    expect(interactions?.count).to(equal(1))
                    expect(interactions?.map { $0.body }).to(equal(["Test"]))
                }
                
                // MARK: ---- always tries to load messages from the current users conversation
                it("always tries to load messages from the current users conversation") {
                    mockCrypto
                        .when {
                            $0.generate(.hash(
                                message: Array("ConvoIdSalt-05\(TestConstants.publicKey)".data(using: .utf8)!)
                            ))
                        }
                        .thenReturn(Array(Data(hex: "0000550000")))
                    
                    await expect { try await extensionHelper.loadMessages() }.toNot(throwError())
                    expect(mockFileManager).to(call(matchingParameters: .all) {
                        try $0.contentsOfDirectory(
                            atPath: "/test/extensionCache/conversations/0000550000/config"
                        )
                    })
                    expect(mockFileManager).to(call(matchingParameters: .all) {
                        try $0.contentsOfDirectory(
                            atPath: "/test/extensionCache/conversations/0000550000/read"
                        )
                    })
                    expect(mockFileManager).to(call(matchingParameters: .all) {
                        try $0.contentsOfDirectory(
                            atPath: "/test/extensionCache/conversations/0000550000/unread"
                        )
                    })
                }
                
                // MARK: ---- loads config messages before other messages
                it("loads config messages before other messages") {
                    await expect { try await extensionHelper.loadMessages() }.toNot(throwError())
                    
                    let key: FunctionConsumer.Key = FunctionConsumer.Key(
                        name: "contentsOfDirectory(atPath:)",
                        generics: [],
                        paramCount: 1
                    )
                    let expectedPaths: [String] = [
                        "/test/extensionCache/conversations/010203/config",
                        "/test/extensionCache/conversations/010203/read",
                        "/test/extensionCache/conversations/010203/unread",
                        "/test/extensionCache/conversations/a/config",
                        "/test/extensionCache/conversations/a/read",
                        "/test/extensionCache/conversations/a/unread"
                    ]
                    let expectedCalls: [CallDetails] = [
                        CallDetails(
                            parameterSummary: "[/test/extensionCache/conversations]",
                            allParameterSummaryCombinations: [
                                ParameterCombination(count: 0, summary: "[]"),
                                ParameterCombination(count: 1, summary: "[/test/extensionCache/conversations]")
                            ]
                        )
                    ]
                    /// Initial call to load messages
                    .appending(contentsOf: expectedPaths.map {
                        CallDetails(
                            parameterSummary: "[\($0)]",
                            allParameterSummaryCombinations: [
                                ParameterCombination(count: 0, summary: "[]"),
                                ParameterCombination(count: 1, summary: "[\($0)]")
                            ]
                        )
                    })
                    /// Subsequent call to check for empty directory for deletion
                    .appending(contentsOf: expectedPaths.map {
                        CallDetails(
                            parameterSummary: "[\($0)]",
                            allParameterSummaryCombinations: [
                                ParameterCombination(count: 0, summary: "[]"),
                                ParameterCombination(count: 1, summary: "[\($0)]")
                            ]
                        )
                    })
                    
                    
                    expect(mockFileManager.functionConsumer.calls[key]).to(equal(expectedCalls))
                }
                
                // MARK: ---- removes messages from disk
                it("removes messages from disk") {
                    mockFileManager.when { try $0.contentsOfDirectory(atPath: .any) }.thenReturn([])
                    mockCrypto
                        .when {
                            $0.generate(.hash(
                                message: Array("ConvoIdSalt-05\(TestConstants.publicKey)".data(using: .utf8)!)
                            ))
                        }
                        .thenReturn(Array(Data(hex: "0000550000")))
                    
                    await expect { try await extensionHelper.loadMessages() }.toNot(throwError())
                    expect(mockFileManager).to(call(matchingParameters: .all) {
                        try $0.removeItem(
                            atPath: "/test/extensionCache/conversations/0000550000/config/g"
                        )
                    })
                    expect(mockFileManager).to(call(matchingParameters: .all) {
                        try $0.removeItem(
                            atPath: "/test/extensionCache/conversations/0000550000/read/h"
                        )
                    })
                    expect(mockFileManager).to(call(matchingParameters: .all) {
                        try $0.removeItem(
                            atPath: "/test/extensionCache/conversations/0000550000/unread/i"
                        )
                    })
                }
                
                // MARK: ---- logs when finished
                it("logs when finished") {
                    await mockLogger.clearLogs()    // Clear logs first to make it easier to debug
                    mockValues.forEach { key, value in
                        mockFileManager
                            .when { try $0.contentsOfDirectory(atPath: key) }
                            .thenReturn([])
                    }
                    mockFileManager
                        .when { try $0.contentsOfDirectory(atPath: "/test/extensionCache/conversations") }
                        .thenReturn(["a"])
                    mockFileManager
                        .when { try $0.contentsOfDirectory(atPath: "/test/extensionCache/conversations/a/read") }
                        .thenReturn(["c"])
                    
                    await expect { try await extensionHelper.loadMessages() }.toNot(throwError())
                    await expect { await mockLogger.logs }.toEventually(contain(
                        MockLogger.LogOutput(
                            level: .info,
                            categories: [
                                Log.Category.create(
                                    "ExtensionHelper",
                                    group: nil,
                                    customSuffix: "",
                                    defaultLevel: .info
                                )
                            ],
                            message: "Finished: Successfully processed 1/1 standard messages, 0/0 config messages.",
                            file: "SessionMessagingKit/ExtensionHelper.swift",
                            function: "loadMessages()"
                        )
                    ))
                }
                
                // MARK: ---- logs an error when failing to process a config message
                it("logs an error when failing to process a config message") {
                    await mockLogger.clearLogs()    // Clear logs first to make it easier to debug
                    mockValues.forEach { key, value in
                        mockFileManager
                            .when { try $0.contentsOfDirectory(atPath: key) }
                            .thenReturn([])
                    }
                    mockFileManager
                        .when { try $0.contentsOfDirectory(atPath: "/test/extensionCache/conversations") }
                        .thenReturn(["a"])
                    mockFileManager
                        .when { try $0.contentsOfDirectory(atPath: "/test/extensionCache/conversations/a/config") }
                        .thenReturn(["b"])
                    mockCrypto
                        .when { $0.generate(.plaintextWithXChaCha20(ciphertext: .any, encKey: .any)) }
                        .thenReturn(nil)
                    
                    await expect { try await extensionHelper.loadMessages() }.toNot(throwError())
                    await expect { await mockLogger.logs }.toEventually(contain(
                        MockLogger.LogOutput(
                            level: .error,
                            categories: [
                                Log.Category.create(
                                    "ExtensionHelper",
                                    group: nil,
                                    customSuffix: "",
                                    defaultLevel: .info
                                )
                            ],
                            message: "Discarding some config message changes due to error: Failed to read from file.",
                            file: "SessionMessagingKit/ExtensionHelper.swift",
                            function: "loadMessages()"
                        )
                    ))
                    await expect { await mockLogger.logs }.toEventually(contain(
                        MockLogger.LogOutput(
                            level: .info,
                            categories: [
                                Log.Category.create(
                                    "ExtensionHelper",
                                    group: nil,
                                    customSuffix: "",
                                    defaultLevel: .info
                                )
                            ],
                            message: "Finished: Successfully processed 0/0 standard messages, 0/1 config messages.",
                            file: "SessionMessagingKit/ExtensionHelper.swift",
                            function: "loadMessages()"
                        )
                    ))
                }
                
                // MARK: ---- logs an error when failing to process a standard message
                it("logs an error when failing to process a standard message") {
                    await mockLogger.clearLogs()    // Clear logs first to make it easier to debug
                    mockValues.forEach { key, value in
                        mockFileManager
                            .when { try $0.contentsOfDirectory(atPath: key) }
                            .thenReturn([])
                    }
                    mockFileManager
                        .when { try $0.contentsOfDirectory(atPath: "/test/extensionCache/conversations") }
                        .thenReturn(["a"])
                    mockFileManager
                        .when { try $0.contentsOfDirectory(atPath: "/test/extensionCache/conversations/a/read") }
                        .thenReturn(["c"])
                    mockCrypto
                        .when { $0.generate(.plaintextWithXChaCha20(ciphertext: .any, encKey: .any)) }
                        .thenReturn(nil)
                    
                    await expect { try await extensionHelper.loadMessages() }.toNot(throwError())
                    await expect { await mockLogger.logs }.toEventually(contain(
                        MockLogger.LogOutput(
                            level: .error,
                            categories: [
                                Log.Category.create(
                                    "ExtensionHelper",
                                    group: nil,
                                    customSuffix: "",
                                    defaultLevel: .info
                                )
                            ],
                            message: "Discarding standard message due to error: Failed to read from file.",
                            file: "SessionMessagingKit/ExtensionHelper.swift",
                            function: "loadMessages()"
                        )
                    ))
                    await expect { await mockLogger.logs }.toEventually(contain(
                        MockLogger.LogOutput(
                            level: .info,
                            categories: [
                                Log.Category.create(
                                    "ExtensionHelper",
                                    group: nil,
                                    customSuffix: "",
                                    defaultLevel: .info
                                )
                            ],
                            message: "Finished: Successfully processed 0/1 standard messages, 0/0 config messages.",
                            file: "SessionMessagingKit/ExtensionHelper.swift",
                            function: "loadMessages()"
                        )
                    ))
                }
                
                // MARK: ---- succeeds even if it fails to remove files after processing
                it("succeeds even if it fails to remove files after processing") {
                    await mockLogger.clearLogs()    // Clear logs first to make it easier to debug
                    mockValues.forEach { key, value in
                        mockFileManager
                            .when { try $0.contentsOfDirectory(atPath: key) }
                            .thenReturn([])
                    }
                    mockFileManager
                        .when { try $0.contentsOfDirectory(atPath: "/test/extensionCache/conversations") }
                        .thenReturn(["a"])
                    mockFileManager
                        .when { try $0.contentsOfDirectory(atPath: "/test/extensionCache/conversations/a/read") }
                        .thenReturn(["c"])
                    mockFileManager.when { try $0.removeItem(atPath: .any) }.thenThrow(TestError.mock)
                    mockCrypto
                        .when {
                            $0.generate(.hash(
                                message: Array("ConvoIdSalt-05\(TestConstants.publicKey)".data(using: .utf8)!)
                            ))
                        }
                        .thenReturn(Array(Data(hex: "0000550000")))
                    
                    await expect { try await extensionHelper.loadMessages() }.toNot(throwError())
                    await expect { await mockLogger.logs }.toEventually(contain(
                        MockLogger.LogOutput(
                            level: .info,
                            categories: [
                                Log.Category.create(
                                    "ExtensionHelper",
                                    group: nil,
                                    customSuffix: "",
                                    defaultLevel: .info
                                )
                            ],
                            message: "Finished: Successfully processed 1/1 standard messages, 0/0 config messages.",
                            file: "SessionMessagingKit/ExtensionHelper.swift",
                            function: "loadMessages()"
                        )
                    ))
                }
            }
        }
    }
}
