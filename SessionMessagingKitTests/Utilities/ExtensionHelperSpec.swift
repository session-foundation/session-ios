// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionSnodeKit
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class ExtensionHelperSpec: QuickSpec {
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
            migrationTargets: [
                SNUtilitiesKit.self,
                SNMessagingKit.self
            ],
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
            initialSetup: { fileManager in
                fileManager.when { $0.appSharedDataDirectoryPath }.thenReturn("/test")
                fileManager
                    .when { try $0.ensureDirectoryExists(at: .any, fileProtectionType: .any) }
                    .thenReturn(())
                fileManager
                    .when { try $0.protectFileOrFolder(at: .any, fileProtectionType: .any) }
                    .thenReturn(())
                fileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                fileManager.when { $0.temporaryFilePath(fileExtension: .any) }.thenReturn("tmpFile")
                fileManager.when { try $0.removeItem(atPath: .any) }.thenReturn(())
                fileManager
                    .when { $0.createFile(atPath: .any, contents: .any, attributes: .any) }
                    .thenReturn(true)
                fileManager.when { try $0.moveItem(atPath: .any, toPath: .any) }.thenReturn(())
                fileManager.when { try $0.setAttributes(.any, ofItemAtPath: .any) }.thenReturn(())
                fileManager.when { $0.contents(atPath: .any) }.thenReturn(Data([1, 2, 3]))
                fileManager.when { try $0.contentsOfDirectory(atPath: .any) }.thenReturn([])
                fileManager.when { $0.isDirectoryEmpty(atPath: .any) }.thenReturn(true)
            }
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
        @TestState var mockLogger: MockLogger! = MockLogger(primaryPrefix: "Mock", using: dependencies)
        
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
                    try? extensionHelper.createDedupeRecord(
                        threadId: "threadId",
                        uniqueIdentifier: "uniqueId"
                    )
                    
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        $0.createFile(atPath: "tmpFile", contents: Data([4, 5, 6]))
                    })
                }
                
                // MARK: ---- removes any existing file from the destination path
                it("removes any existing file from the destination path") {
                    try? extensionHelper.createDedupeRecord(
                        threadId: "threadId",
                        uniqueIdentifier: "uniqueId"
                    )
                    
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try $0.removeItem(atPath: "/test/extensionCache/conversations/010203/dedupe/010203")
                    })
                }
                
                // MARK: ---- moves the temporary file to the destination path
                it("moves the temporary file to the destination path") {
                    try? extensionHelper.createDedupeRecord(
                        threadId: "threadId",
                        uniqueIdentifier: "uniqueId"
                    )
                    
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try $0.moveItem(
                            atPath: "tmpFile",
                            toPath: "/test/extensionCache/conversations/010203/dedupe/010203"
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
                        .when { $0.createFile(atPath: .any, contents: .any) }
                        .thenReturn(false)
                    
                    expect {
                        try extensionHelper.createDedupeRecord(
                            threadId: "threadId",
                            uniqueIdentifier: "uniqueId"
                        )
                    }.to(throwError(ExtensionHelperError.failedToWriteToFile))
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
                        .when { try $0.moveItem(atPath: .any, toPath: .any) }
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
                        $0.createFile(atPath: "tmpFile", contents: Data(base64Encoded: "BAUG"))
                    })
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try $0.moveItem(atPath: "tmpFile", toPath: "/test/extensionCache/metadata")
                    })
                }
                
                // MARK: ---- throws when failing to write the file
                it("throws when failing to write the file") {
                    mockFileManager
                        .when { try $0.moveItem(atPath: .any, toPath: .any) }
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
                    mockFileManager.when { $0.contents(atPath: .any) }.thenReturn(Data([1, 2, 3]))
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
                    mockFileManager.when { $0.contents(atPath: .any) }.thenReturn(nil)
                    
                    let result: ExtensionHelper.UserMetadata? = extensionHelper.loadUserMetadata()
                    
                    expect(result).to(beNil())
                }
                
                // MARK: ---- returns null if it fails to decrypt the file
                it("returns null if it fails to decrypt the file") {
                    mockFileManager.when { $0.contents(atPath: .any) }.thenReturn(Data([1, 2, 3]))
                    mockCrypto
                        .when { $0.generate(.plaintextWithXChaCha20(ciphertext: .any, encKey: .any)) }
                        .thenReturn(nil)
                    
                    let result: ExtensionHelper.UserMetadata? = extensionHelper.loadUserMetadata()
                    
                    expect(result).to(beNil())
                }
                
                // MARK: ---- returns null if it fails to decode the data
                it("returns null if it fails to decode the data") {
                    mockFileManager.when { $0.contents(atPath: .any) }.thenReturn(Data([1, 2, 3]))
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
            // MARK: -- when checking whether a single dedupe record exists
            context("when checking whether a single dedupe record exists") {
                // MARK: ---- returns true when at least one record exists
                it("returns true when at least one record exists") {
                    mockFileManager.when { $0.isDirectoryEmpty(atPath: .any) }.thenReturn(false)
                    
                    expect(extensionHelper.hasAtLeastOneDedupeRecord(threadId: "threadId")).to(beTrue())
                }
                
                // MARK: ---- returns false when a record does not exist
                it("returns false when a record does not exist") {
                    mockFileManager.when { $0.isDirectoryEmpty(atPath: .any) }.thenReturn(true)
                    
                    expect(extensionHelper.hasAtLeastOneDedupeRecord(threadId: "threadId")).to(beFalse())
                }
                
                // MARK: ---- returns false when failing to generate a hash
                it("returns false when failing to generate a hash") {
                    mockFileManager.when { $0.isDirectoryEmpty(atPath: .any) }.thenReturn(false)
                    mockCrypto.when { $0.generate(.hash(message: .any)) }.thenReturn(nil)
                    
                    expect(extensionHelper.hasAtLeastOneDedupeRecord(threadId: "threadId")).to(beFalse())
                }
            }
            
            // MARK: -- when checking for dedupe records
            context("when checking for dedupe records") {
                // MARK: ---- returns true when a record exists
                it("returns true when a record exists") {
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
                        try? $0.moveItem(
                            atPath: "tmpFile",
                            toPath: "/test/extensionCache/conversations/010203/dedupe/010203"
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
                        .when { try $0.moveItem(atPath: .any, toPath: .any) }
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
                        $0.createFile(atPath: "tmpFile", contents: Data(base64Encoded: "BAUG"))
                    })
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try $0.moveItem(
                            atPath: "tmpFile",
                            toPath: "/test/extensionCache/conversations/010203/dumps/010203"
                        )
                    })
                }
                
                // MARK: ---- does nothing when given a null dump
                it("does nothing when given a null dump") {
                    extensionHelper.replicate(dump: nil, replaceExisting: true)
                    
                    expect(mockFileManager).toNot(call { $0.createFile(atPath: .any, contents: .any) })
                    expect(mockFileManager).toNot(call { try $0.moveItem(atPath: .any, toPath: .any) })
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
                    
                    expect(mockFileManager).toNot(call { $0.createFile(atPath: .any, contents: .any) })
                    expect(mockFileManager).toNot(call { try $0.moveItem(atPath: .any, toPath: .any) })
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
                    
                    expect(mockFileManager).toNot(call { $0.createFile(atPath: .any, contents: .any) })
                    expect(mockFileManager).toNot(call { try $0.moveItem(atPath: .any, toPath: .any) })
                }
                
                // MARK: ---- logs an error when failing to write the file
                it("logs an error when failing to write the file") {
                    mockFileManager
                        .when { try $0.moveItem(atPath: .any, toPath: .any) }
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
                    
                    expect(mockLogger.logs).to(equal([
                        MockLogger.LogOutput(
                            level: .error,
                            categories: [
                                Log.Category.create(
                                    "ExtensionHelper",
                                    customPrefix: "",
                                    customSuffix: "",
                                    defaultLevel: .info
                                )
                            ],
                            message: "Failed to replicate userProfile dump for 05\(TestConstants.publicKey).",
                            file: "SessionMessagingKit/ExtensionHelper.swift",
                            function: "replicate(dump:replaceExisting:)"
                        )
                    ]))
                }
            }
            
            // MARK: -- when replicating all config dumps
            context("when replicating all config dumps") {
                @TestState var mockValues: [String: [UInt8]]! = [
                    "ConvoIdSalt-05\(TestConstants.publicKey)": [1, 2, 3],
                    "DumpSalt-\(ConfigDump.Variant.userProfile)": [2, 3, 4],
                    "ConvoIdSalt-03\(TestConstants.publicKey)": [4, 5, 6],
                    "DumpSalt-\(ConfigDump.Variant.groupInfo)": [5, 6, 7]
                ]
                
                beforeEach {
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(false)
                    mockValues.forEach { key, value in
                        mockCrypto
                            .when { $0.generate(.hash(message: Array(key.data(using: .utf8)!))) }
                            .thenReturn(value)
                    }
                    mockCrypto
                        .when { $0.generate(.ciphertextWithXChaCha20(plaintext: Data([2, 3, 4]), encKey: .any)) }
                        .thenReturn(Data([2, 3, 4]))
                    mockCrypto
                        .when { $0.generate(.ciphertextWithXChaCha20(plaintext: Data([5, 6, 7]), encKey: .any)) }
                        .thenReturn(Data([5, 6, 7]))
                    
                    mockStorage.write { db in
                        try ConfigDump(
                            variant: .userProfile,
                            sessionId: "05\(TestConstants.publicKey)",
                            data: Data([2, 3, 4]),
                            timestampMs: 1234567890
                        ).insert(db)
                        try ConfigDump(
                            variant: .groupInfo,
                            sessionId: "03\(TestConstants.publicKey)",
                            data: Data([5, 6, 7]),
                            timestampMs: 1234567890
                        ).insert(db)
                    }
                }
                
                // MARK: ---- replicates successfully
                it("replicates successfully") {
                    extensionHelper.replicateAllConfigDumpsIfNeeded(
                        userSessionId: SessionId(.standard, hex: "05\(TestConstants.publicKey)")
                    )
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        $0.createFile(atPath: "tmpFile", contents: Data(base64Encoded: "AgME"))
                    })
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try $0.moveItem(
                            atPath: "tmpFile",
                            toPath: "/test/extensionCache/conversations/010203/dumps/020304"
                        )
                    })
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        $0.createFile(atPath: "tmpFile", contents: Data(base64Encoded: "BQYH"))
                    })
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try $0.moveItem(
                            atPath: "tmpFile",
                            toPath: "/test/extensionCache/conversations/040506/dumps/050607"
                        )
                    })
                }
                
                // MARK: ---- does nothing when failing to generate a hash
                it("does nothing when failing to generate a hash") {
                    mockValues.forEach { key, value in
                        mockCrypto
                            .when { $0.generate(.hash(message: Array(key.data(using: .utf8)!))) }
                            .thenReturn(nil)
                    }
                    
                    extensionHelper.replicateAllConfigDumpsIfNeeded(
                        userSessionId: SessionId(.standard, hex: "05\(TestConstants.publicKey)")
                    )
                    
                    expect(mockFileManager).toNot(call { $0.createFile(atPath: .any, contents: .any) })
                    expect(mockFileManager).toNot(call { try $0.moveItem(atPath: .any, toPath: .any) })
                }
                
                // MARK: ---- does nothing if the user profile dump already exists
                it("does nothing if the user profile dump already exists") {
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    
                    extensionHelper.replicateAllConfigDumpsIfNeeded(
                        userSessionId: SessionId(.standard, hex: "05\(TestConstants.publicKey)")
                    )
                    
                    expect(mockFileManager).toNot(call { $0.createFile(atPath: .any, contents: .any) })
                    expect(mockFileManager).toNot(call { try $0.moveItem(atPath: .any, toPath: .any) })
                }
                
                // MARK: ---- does nothing if there are no dumps in the database
                it("does nothing if there are no dumps in the database") {
                    mockStorage.write { db in try ConfigDump.deleteAll(db) }
                    
                    extensionHelper.replicateAllConfigDumpsIfNeeded(
                        userSessionId: SessionId(.standard, hex: "05\(TestConstants.publicKey)")
                    )
                    
                    expect(mockFileManager).toNot(call { $0.createFile(atPath: .any, contents: .any) })
                    expect(mockFileManager).toNot(call { try $0.moveItem(atPath: .any, toPath: .any) })
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
                        userSessionId: SessionId(.standard, hex: "05\(TestConstants.publicKey)")
                    )
                    
                    expect(mockFileManager).toNot(call { $0.createFile(atPath: .any, contents: .any) })
                    expect(mockFileManager).toNot(call { try $0.moveItem(atPath: .any, toPath: .any) })
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
                
                // MARK: ---- does nothing if it cannot get a dump for the config
                it("does nothing if it cannot get a dump for the config") {
                    mockFileManager.when { $0.contents(atPath: .any) }.thenReturn(nil)
                    
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
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    
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
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    
                    expect(extensionHelper.unreadMessageCount()).to(equal(6))
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
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    
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
                    mockFileManager.when { $0.fileExists(atPath: .any) }.thenReturn(true)
                    
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
                    
                    expect(extensionHelper.unreadMessageCount()).to(equal(3))
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
                            isUnread: false
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
                            isUnread: false
                        )
                    }.toNot(throwError())
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try $0.moveItem(
                            atPath: "tmpFile",
                            toPath: "/test/extensionCache/conversations/010203/config/010203"
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
                            isUnread: true
                        )
                    }.toNot(throwError())
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try $0.moveItem(
                            atPath: "tmpFile",
                            toPath: "/test/extensionCache/conversations/010203/unread/010203"
                        )
                    })
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
                            isUnread: false
                        )
                    }.toNot(throwError())
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try $0.moveItem(
                            atPath: "tmpFile",
                            toPath: "/test/extensionCache/conversations/010203/read/010203"
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
                            isUnread: false
                        )
                    }.toNot(throwError())
                    expect(mockFileManager).toNot(call {
                        try $0.moveItem(atPath: .any, toPath: .any)
                    })
                }
                
                // MARK: ---- throws when failing to write the file
                it("throws when failing to write the file") {
                    mockFileManager
                        .when { try $0.moveItem(atPath: .any, toPath: .any) }
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
                            isUnread: false
                        )
                    }.to(throwError(TestError.mock))
                }
            }
            
            // MARK: -- when waiting for messages to be loaded
            context("when waiting for messages to be loaded") {
                // MARK: ---- stops waiting once messages are loaded
                it("stops waiting once messages are loaded") {
                    var loadCompleted: Bool?
                    let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
                    Task {
                        loadCompleted = await extensionHelper.waitUntilMessagesAreLoaded(timeout: .milliseconds(150))
                        semaphore.signal()
                    }
                    Task {
                        try await extensionHelper.loadMessages()
                    }
                    let result = semaphore.wait(timeout: .now() + .milliseconds(100))
                    expect(result).to(equal(.success))
                    expect(loadCompleted).to(beTrue())
                }
                
                // MARK: ---- times out if it takes longer than the timeout specified
                it("times out if it takes longer than the timeout specified") {
                    var loadCompleted: Bool?
                    let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
                    Task {
                        loadCompleted = await extensionHelper.waitUntilMessagesAreLoaded(timeout: .milliseconds(50))
                        semaphore.signal()
                    }
                    let result = semaphore.wait(timeout: .now() + .milliseconds(100))
                    expect(result).to(equal(.success))
                    expect(loadCompleted).to(beFalse())
                }
                
                // MARK: ---- does not wait if messages have already been loaded
                it("does not wait if messages have already been loaded") {
                    var loadCompleted: Bool?
                    let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
                    Task {
                        try? await extensionHelper.loadMessages()
                        loadCompleted = await extensionHelper.waitUntilMessagesAreLoaded(timeout: .milliseconds(100))
                        semaphore.signal()
                    }
                    let result = semaphore.wait(timeout: .now() + .milliseconds(50))
                    expect(result).to(equal(.success))
                    expect(loadCompleted).to(beTrue())
                }
                
                // MARK: ---- waits if messages have already been loaded but we indicate we will load them again
                it("waits if messages have already been loaded but we indicate we will load them again") {
                    var loadCompleted: Bool?
                    let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
                    Task {
                        try? await extensionHelper.loadMessages()
                        extensionHelper.willLoadMessages()
                        loadCompleted = await extensionHelper.waitUntilMessagesAreLoaded(timeout: .milliseconds(50))
                        semaphore.signal()
                    }
                    let result = semaphore.wait(timeout: .now() + .milliseconds(100))
                    expect(result).to(equal(.success))
                    expect(loadCompleted).to(beFalse())
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
                    mockFileManager.when { $0.contents(atPath: .any) }.thenReturn(Data([1, 2, 3]))
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
                    let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
                    Task {
                        try await extensionHelper.loadMessages()
                        semaphore.signal()
                    }
                    let result = semaphore.wait(timeout: .now() + .milliseconds(100))
                    expect(result).to(equal(.success))
                    
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
                    
                    let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
                    Task {
                        try await extensionHelper.loadMessages()
                        semaphore.signal()
                    }
                    let result = semaphore.wait(timeout: .now() + .milliseconds(100))
                    expect(result).to(equal(.success))
                    
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
                    let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
                    Task {
                        try await extensionHelper.loadMessages()
                        semaphore.signal()
                    }
                    let result = semaphore.wait(timeout: .now() + .milliseconds(100))
                    expect(result).to(equal(.success))
                    
                    let key: FunctionConsumer.Key = FunctionConsumer.Key(
                        name: "contentsOfDirectory(atPath:)",
                        generics: [],
                        paramCount: 1
                    )
                    expect(mockFileManager.functionConsumer.calls[key]).to(equal([
                        CallDetails(
                            parameterSummary: "[/test/extensionCache/conversations]",
                            allParameterSummaryCombinations: [
                                ParameterCombination(count: 0, summary: "[]"),
                                ParameterCombination(count: 1, summary: "[/test/extensionCache/conversations]")
                            ]
                        ),
                        CallDetails(
                            parameterSummary: "[/test/extensionCache/conversations/010203/config]",
                            allParameterSummaryCombinations: [
                                ParameterCombination(count: 0, summary: "[]"),
                                ParameterCombination(
                                    count: 1,
                                    summary: "[/test/extensionCache/conversations/010203/config]"
                                )
                            ]
                        ),
                        CallDetails(
                            parameterSummary: "[/test/extensionCache/conversations/010203/read]",
                            allParameterSummaryCombinations: [
                                ParameterCombination(count: 0, summary: "[]"),
                                ParameterCombination(
                                    count: 1,
                                    summary: "[/test/extensionCache/conversations/010203/read]"
                                )
                            ]
                        ),
                        CallDetails(
                            parameterSummary: "[/test/extensionCache/conversations/010203/unread]",
                            allParameterSummaryCombinations: [
                                ParameterCombination(count: 0, summary: "[]"),
                                ParameterCombination(
                                    count: 1,
                                    summary: "[/test/extensionCache/conversations/010203/unread]"
                                )
                            ]
                        ),
                        CallDetails(
                            parameterSummary: "[/test/extensionCache/conversations/a/config]",
                            allParameterSummaryCombinations: [
                                ParameterCombination(count: 0, summary: "[]"),
                                ParameterCombination(
                                    count: 1,
                                    summary: "[/test/extensionCache/conversations/a/config]"
                                )
                            ]
                        ),
                        CallDetails(
                            parameterSummary: "[/test/extensionCache/conversations/a/read]",
                            allParameterSummaryCombinations: [
                                ParameterCombination(count: 0, summary: "[]"),
                                ParameterCombination(
                                    count: 1,
                                    summary: "[/test/extensionCache/conversations/a/read]"
                                )
                            ]
                        ),
                        CallDetails(
                            parameterSummary: "[/test/extensionCache/conversations/a/unread]",
                            allParameterSummaryCombinations: [
                                ParameterCombination(count: 0, summary: "[]"),
                                ParameterCombination(
                                    count: 1,
                                    summary: "[/test/extensionCache/conversations/a/unread]"
                                )
                            ]
                        )
                    ]))
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
                    
                    let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
                    Task {
                        try await extensionHelper.loadMessages()
                        semaphore.signal()
                    }
                    let result = semaphore.wait(timeout: .now() + .milliseconds(100))
                    expect(result).to(equal(.success))
                    
                    expect(mockFileManager).to(call(matchingParameters: .all) {
                        try $0.removeItem(
                            atPath: "/test/extensionCache/conversations/0000550000/config"
                        )
                    })
                    expect(mockFileManager).to(call(matchingParameters: .all) {
                        try $0.removeItem(
                            atPath: "/test/extensionCache/conversations/0000550000/read"
                        )
                    })
                    expect(mockFileManager).to(call(matchingParameters: .all) {
                        try $0.removeItem(
                            atPath: "/test/extensionCache/conversations/0000550000/unread"
                        )
                    })
                }
                
                // MARK: ---- logs when finished
                it("logs when finished") {
                    mockLogger.logs = []    // Clear logs first to make it easier to debug
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
                    
                    let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
                    Task {
                        try await extensionHelper.loadMessages()
                        semaphore.signal()
                    }
                    let result = semaphore.wait(timeout: .now() + .milliseconds(100))
                    expect(result).to(equal(.success))
                    
                    expect(mockLogger.logs).to(contain(
                        MockLogger.LogOutput(
                            level: .info,
                            categories: [
                                Log.Category.create(
                                    "ExtensionHelper",
                                    customPrefix: "",
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
                    mockLogger.logs = []    // Clear logs first to make it easier to debug
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
                    
                    let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
                    Task {
                        try await extensionHelper.loadMessages()
                        semaphore.signal()
                    }
                    let result = semaphore.wait(timeout: .now() + .milliseconds(100))
                    expect(result).to(equal(.success))
                    
                    expect(mockLogger.logs).to(contain(
                        MockLogger.LogOutput(
                            level: .error,
                            categories: [
                                Log.Category.create(
                                    "ExtensionHelper",
                                    customPrefix: "",
                                    customSuffix: "",
                                    defaultLevel: .info
                                )
                            ],
                            message: "Discarding some config message changes due to error: Failed to read from file.",
                            file: "SessionMessagingKit/ExtensionHelper.swift",
                            function: "loadMessages()"
                        )
                    ))
                    expect(mockLogger.logs).to(contain(
                        MockLogger.LogOutput(
                            level: .info,
                            categories: [
                                Log.Category.create(
                                    "ExtensionHelper",
                                    customPrefix: "",
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
                    mockLogger.logs = []    // Clear logs first to make it easier to debug
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
                    
                    let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
                    Task {
                        try await extensionHelper.loadMessages()
                        semaphore.signal()
                    }
                    let result = semaphore.wait(timeout: .now() + .milliseconds(100))
                    expect(result).to(equal(.success))
                    
                    expect(mockLogger.logs).to(contain(
                        MockLogger.LogOutput(
                            level: .error,
                            categories: [
                                Log.Category.create(
                                    "ExtensionHelper",
                                    customPrefix: "",
                                    customSuffix: "",
                                    defaultLevel: .info
                                )
                            ],
                            message: "Discarding standard message due to error: Failed to read from file.",
                            file: "SessionMessagingKit/ExtensionHelper.swift",
                            function: "loadMessages()"
                        )
                    ))
                    expect(mockLogger.logs).to(contain(
                        MockLogger.LogOutput(
                            level: .info,
                            categories: [
                                Log.Category.create(
                                    "ExtensionHelper",
                                    customPrefix: "",
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
                    mockLogger.logs = []    // Clear logs first to make it easier to debug
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
                    
                    let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
                    Task {
                        try await extensionHelper.loadMessages()
                        semaphore.signal()
                    }
                    let result = semaphore.wait(timeout: .now() + .milliseconds(100))
                    expect(result).to(equal(.success))
                    
                    expect(mockLogger.logs).to(contain(
                        MockLogger.LogOutput(
                            level: .info,
                            categories: [
                                Log.Category.create(
                                    "ExtensionHelper",
                                    customPrefix: "",
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
