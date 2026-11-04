// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import GRDB
import TestUtilities

import Quick
import Nimble

@testable import SessionNetworkingKit
@testable import SessionMessagingKit
@testable import SessionUtilitiesKit

class AttachmentDownloadJobSpec: AsyncSpec {
    override class func spec() {
        @TestState var fixture: AttachmentDownloadJobTestFixture!
        
        beforeEach {
            fixture = try await AttachmentDownloadJobTestFixture.create()
        }
        
        // MARK: - an AttachmentDownloadJob
        describe("an AttachmentDownloadJob") {
            // MARK: -- marks the attachment as downloaded when it succeeds
            it("marks the attachment as downloaded when it succeeds") {
                try await fixture.insertAttachment(downloadUrl: AttachmentDownloadJobTestFixture.streamUrl)
                
                let error: Error? = await fixture.runJob()
                
                expect(error).to(beNil())
                await expect { try await fixture.attachmentState() }.to(equal(.downloaded))
            }
            
            // MARK: -- when failing after the download
            context("when failing after the download") {
                // MARK: ---- marks the attachment as invalid when legacy decryption fails
                it("marks the attachment as invalid when legacy decryption fails") {
                    try await fixture.insertAttachment(
                        downloadUrl: AttachmentDownloadJobTestFixture.legacyUrl,
                        digest: Data(repeating: 2, count: 32)
                    )
                    try await fixture.mockCrypto
                        .when {
                            try $0.tryGenerate(
                                .legacyDecryptAttachment(ciphertext: .any, key: .any, digest: .any, unpaddedSize: .any)
                            )
                        }
                        .thenThrow(AttachmentError.legacyDecryptionFailed)
                    
                    let error: Error? = await fixture.runJob()
                    
                    expect((error as? JobError)?.isPermanent).to(beTrue())
                    await expect { try await fixture.attachmentState() }.to(equal(.invalid))
                }
                
                // MARK: ---- marks the attachment as failed when stream decryption fails
                it("marks the attachment as failed when stream decryption fails") {
                    try await fixture.insertAttachment(downloadUrl: AttachmentDownloadJobTestFixture.streamUrl)
                    try await fixture.mockCrypto
                        .when {
                            try $0.tryGenerate(
                                .decryptAttachmentToFile(filePath: .any, destinationPath: .any, key: .any)
                            )
                        }
                        .thenThrow(CryptoError.decryptionFailed)
                    
                    let error: Error? = await fixture.runJob()
                    
                    expect((error as? JobError)?.isPermanent).to(beTrue())
                    await expect { try await fixture.attachmentState() }.to(equal(.failedDownload))
                }
                
                // MARK: ---- marks the attachment as invalid when the encryption format is unknown
                it("marks the attachment as invalid when the encryption format is unknown") {
                    /// A key with no digest and no stream fragment on the url
                    try await fixture.insertAttachment(downloadUrl: AttachmentDownloadJobTestFixture.legacyUrl)
                    
                    let error: Error? = await fixture.runJob()
                    
                    expect((error as? JobError)?.isPermanent).to(beTrue())
                    await expect { try await fixture.attachmentState() }.to(equal(.invalid))
                }
                
                // MARK: ---- marks the attachment as failed when the file cannot be saved
                it("marks the attachment as failed when the file cannot be saved") {
                    try await fixture.insertAttachment(downloadUrl: AttachmentDownloadJobTestFixture.streamUrl)
                    
                    /// The destination path is derived from a hash of the url, so this leaves nowhere to save to
                    try await fixture.mockCrypto
                        .when { try $0.tryGenerate(.hash(message: .any)) }
                        .thenThrow(CryptoError.failedToGenerateOutput)
                    
                    let error: Error? = await fixture.runJob()
                    
                    expect(error).to(matchError(AttachmentDownloadJob.AttachmentDownloadError.failedToSaveFile))
                    await expect { try await fixture.attachmentState() }.to(equal(.failedDownload))
                }
                
                // MARK: ---- marks the attachment as failed when cancelled
                it("marks the attachment as failed when cancelled") {
                    try await fixture.insertAttachment(downloadUrl: AttachmentDownloadJobTestFixture.streamUrl)
                    
                    /// Mimics the app being backgrounded while the download is in flight
                    try await fixture.mockNetwork
                        .when {
                            try await $0.download(
                                downloadUrl: .any,
                                stallTimeout: .any,
                                requestTimeout: .any,
                                overallTimeout: .any,
                                partialMinInterval: .any,
                                desiredPathIndex: .any,
                                onProgress: nil
                            )
                        }
                        .then { _ in withUnsafeCurrentTask { $0?.cancel() } }
                        .thenReturn(MockNetwork.downloadResponse())
                    
                    let error: Error? = await Task { await fixture.runJob() }.value
                    
                    expect(error).to(beAKindOf(CancellationError.self))
                    await expect { try await fixture.attachmentState() }.to(equal(.failedDownload))
                }
            }
        }
    }
}

// MARK: - Configuration

private class AttachmentDownloadJobTestFixture: FixtureBase {
    static let attachmentId: String = "TestAttachmentId"
    static let threadId: String = "05\(TestConstants.publicKey)"
    static let legacyUrl: String = "http://filev2.getsession.org/file/1234"
    static let streamUrl: String = "http://filev2.getsession.org/file/abc123#d"
    
    var mockStorage: Storage {
        mock(for: .storage) { dependencies in
            try! Storage.createForTesting(using: dependencies)
        }
    }
    var mockNetwork: MockNetwork { mock(for: .network) }
    var mockAppContext: MockAppContext { mock(for: .appContext) }
    var mockFileManager: MockFileManager { mock(for: .fileManager) }
    var mockCrypto: MockCrypto { mock(for: .crypto) }
    var mockCommunityManager: MockCommunityManager { mock(for: .communityManager) }
    
    static func create() async throws -> AttachmentDownloadJobTestFixture {
        let fixture: AttachmentDownloadJobTestFixture = AttachmentDownloadJobTestFixture()
        try await fixture.applyBaselineStubs()
        
        return fixture
    }
    
    // MARK: - Default State
    
    private func applyBaselineStubs() async throws {
        try await mockStorage.perform(migrations: SNMessagingKit.migrations, onProgressUpdate: nil)
        try await mockAppContext.when { $0.isValid }.thenReturn(true)
        try await mockFileManager.defaultInitialSetup()
        try await mockCommunityManager.defaultInitialSetup()
        try await mockNetwork.defaultInitialSetup(using: dependencies)
        await mockNetwork.removeRequestMocks()
        try await mockNetwork
            .when {
                try await $0.download(
                    downloadUrl: .any,
                    stallTimeout: .any,
                    requestTimeout: .any,
                    overallTimeout: .any,
                    partialMinInterval: .any,
                    desiredPathIndex: .any,
                    onProgress: nil
                )
            }
            .thenReturn(MockNetwork.downloadResponse())
        try await mockCrypto
            .when { try $0.tryGenerate(.hash(message: .any)) }
            .thenReturn(Array(Data(repeating: 1, count: 32)))
        try await mockCrypto
            .when { try $0.tryGenerate(.decryptAttachmentToFile(filePath: .any, destinationPath: .any, key: .any)) }
            .thenReturn(())
    }
    
    // MARK: - Convenience
    
    func insertAttachment(downloadUrl: String, digest: Data? = nil) async throws {
        try await mockStorage.write { db in
            try Attachment(
                id: AttachmentDownloadJobTestFixture.attachmentId,
                variant: .voiceMessage,
                contentType: "audio/mpeg",
                byteCount: 1234,
                downloadUrl: downloadUrl,
                encryptionKey: Data(repeating: 1, count: 64),
                digest: digest
            ).insert(db)
        }
        
        /// Every test asserts on the state the job leaves behind, so make sure it didn't start there
        let initialState: Attachment.State? = try await attachmentState()
        expect(initialState).to(equal(.pendingDownload))
    }
    
    func runJob() async -> Error? {
        let job: Job? = Job(
            variant: .attachmentDownload,
            threadId: AttachmentDownloadJobTestFixture.threadId,
            interactionId: 1,
            details: AttachmentDownloadJob.Details(attachmentId: AttachmentDownloadJobTestFixture.attachmentId)
        )
        
        do {
            _ = try await AttachmentDownloadJob.run(try require(job).toNot(beNil()), using: dependencies)
            return nil
        }
        catch { return error }
    }
    
    func attachmentState() async throws -> Attachment.State? {
        return try await mockStorage.read { db in
            try Attachment.fetchOne(db, id: AttachmentDownloadJobTestFixture.attachmentId)?.state
        }
    }
}
