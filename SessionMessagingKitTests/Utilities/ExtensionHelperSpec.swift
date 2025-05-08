// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class ExtesnionHelperSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState(singleton: .extensionHelper, in: dependencies) var extensionHelper: ExtensionHelper! = ExtensionHelper(using: dependencies)
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
        
        // MARK: - an ExtensionHelper - File Management
        describe("an ExtensionHelper") {
            // MARK: -- when writing an encrypted file
            context("when writing an encrypted file") {
                // MARK: ---- ensures the write directory exists
                it("ensures the write directory exists") {
                    try? extensionHelper.createDedupeRecord(
                        threadId: "threadId",
                        uniqueIdentifier: "uniqueId"
                    )
                    
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try? $0.ensureDirectoryExists(at: "/test/extensionCache/dedupe/010203")
                    })
                }
                
                // MARK: ---- protects the write directory
                it("protects the write directory") {
                    try? extensionHelper.createDedupeRecord(
                        threadId: "threadId",
                        uniqueIdentifier: "uniqueId"
                    )
                    
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try? $0.protectFileOrFolder(at: "/test/extensionCache/dedupe/010203")
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
                        try $0.removeItem(atPath: "/test/extensionCache/dedupe/010203/010203")
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
                            toPath: "/test/extensionCache/dedupe/010203/010203"
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
                            toPath: "/test/extensionCache/dedupe/010203/010203"
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
                        try? $0.removeItem(atPath: "/test/extensionCache/dedupe/010203/010203")
                    })
                }
                
                // MARK: ---- removes the parent directory if it is empty
                it("removes the parent directory if it is empty") {
                    try? extensionHelper.removeDedupeRecord(
                        threadId: "threadId",
                        uniqueIdentifier: "uniqueId"
                    )
                    
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try? $0.removeItem(atPath: "/test/extensionCache/dedupe/010203")
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
                        try? $0.removeItem(atPath: "/test/extensionCache/dedupe/010203")
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
                        try? $0.removeItem(atPath: "/test/extensionCache/dedupe/010203/010203")
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
            
            // MARK: -- when removing all records
            context("when removing all records") {
                // MARK: ---- removes all dedupe records
                it("removes all dedupe records") {
                    extensionHelper.deleteAllDedupeRecords()
                    
                    expect(mockFileManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                        try? $0.removeItem(atPath: "/test/extensionCache/dedupe")
                    })
                }
            }
        }
        
        // MARK: - an ExtensionHelper - Config Dumps
        describe("an ExtensionHelper") {
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
        }
    }
}
