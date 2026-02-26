// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import TestUtilities

import Quick
import Nimble

@testable import SessionNetworkingKit
@testable import SessionMessagingKit
@testable import SessionUtilitiesKit

class DisplayPictureDownloadJobSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var job: Job!
        @TestState var profile: Profile!
        @TestState var group: ClosedGroup!
        @TestState var community: OpenGroup!
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.forceSynchronous = true
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
        }
        @TestState var mockLibSessionCache: MockLibSessionCache! = .create(using: dependencies)
        @TestState var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            using: dependencies
        )
        @TestState var encryptionKey: Data! = Data(hex: "c8e52eb1016702a663ac9a1ab5522daa128ab40762a514de271eddf598e3b8d4")
        @TestState var mockNetwork: MockNetwork! = .create(using: dependencies)
        @TestState var mockFileManager: MockFileManager! = .create(using: dependencies)
        @TestState var mockCrypto: MockCrypto! = .create(using: dependencies)
        @TestState var mockImageDataManager: MockImageDataManager! = .create(using: dependencies)
        @TestState var mockGeneralCache: MockGeneralCache! = .create(using: dependencies)
        @TestState var mockCommunityManager: MockCommunityManager! = .create(using: dependencies)
        
        beforeEach {
            dependencies.set(cache: .general, to: mockGeneralCache)
            try await mockGeneralCache.defaultInitialSetup()
            
            dependencies.set(cache: .libSession, to: mockLibSessionCache)
            try await mockLibSessionCache.defaultInitialSetup()
            await mockLibSessionCache.removeMocksFor {
                $0.profile(contactId: .any, threadId: .any, threadVariant: .any, visibleMessage: .any)
            }
            try await mockLibSessionCache.when {
                $0.profile(contactId: .any, threadId: .any, threadVariant: .any, visibleMessage: .any)
            }.thenReturn(nil)
            
            dependencies.set(singleton: .fileManager, to: mockFileManager)
            try await mockFileManager.defaultInitialSetup()
            
            dependencies.set(singleton: .storage, to: mockStorage)
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            try await mockStorage.writeAsync { db in
                try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).insert(db)
                try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).insert(db)
                try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
            }
            
            dependencies.set(singleton: .crypto, to: mockCrypto)
            try await mockCrypto
                .when { $0.generate(.uuid()) }
                .thenReturn(UUID(uuidString: "00000000-0000-0000-0000-000000001234"))
            try await mockCrypto
                .when { $0.generate(.legacyDecryptedDisplayPicture(data: .any, key: .any)) }
                .thenReturn(TestConstants.validImageData)
            try await mockCrypto
                .when { $0.generate(.hash(message: .any, length: .any)) }
                .thenReturn("TestHash".bytes)
            try await mockCrypto
                .when { $0.generate(.blinded15KeyPair(serverPublicKey: .any, ed25519SecretKey: .any)) }
                .thenReturn(
                    KeyPair(
                        publicKey: Data(hex: TestConstants.publicKey).bytes,
                        secretKey: Data(hex: TestConstants.edSecretKey).bytes
                    )
                )
            try await mockCrypto
                .when { $0.generate(.randomBytes(16)) }
                .thenReturn(Data(base64Encoded: "pK6YRtQApl4NhECGizF0Cg==")!.bytes)
            try await mockCrypto
                .when { $0.generate(.signatureBlind15(message: .any, serverPublicKey: .any, ed25519SecretKey: .any)) }
                .thenReturn("TestSogsSignature".bytes)
            try await mockCrypto
                .when { $0.generate(.x25519(ed25519Pubkey: .any)) }
                .thenReturn(Array(Data(hex: TestConstants.serverPublicKey)))
            
            dependencies.set(singleton: .network, to: mockNetwork)
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
            try await mockNetwork
                .when {
                    try await $0.send(
                        endpoint: MockEndpoint.any,
                        destination: .any,
                        body: .any,
                        category: .any,
                        requestTimeout: .any,
                        overallTimeout: .any
                    )
                }
                .thenReturn(MockNetwork.response(
                    data: TestConstants.validImageData  /// SOGS doesn't encrypt it's images
                ))
            
            dependencies.set(singleton: .imageDataManager, to: mockImageDataManager)
            try await mockImageDataManager
                .when { $0.isValidImage(at: .any) }
                .thenReturn(true)
            try await mockImageDataManager
                .when { await $0.load(.any) }
                .thenReturn(nil)
            try await mockImageDataManager
                .when { await $0.removeImage(identifier: .any) }
                .thenReturn(())
            
            dependencies.set(singleton: .communityManager, to: mockCommunityManager)
            try await mockCommunityManager.defaultInitialSetup()
            try await mockCommunityManager
                .when { await $0.server("testserver") }
                .thenReturn(
                    CommunityManager.Server(
                        server: "testserver",
                        publicKey: TestConstants.serverPublicKey,
                        using: dependencies
                    )
                )
        }
        
        // MARK: - a DisplayPictureDownloadJob
        describe("a DisplayPictureDownloadJob") {
            // MARK: -- fails when not given any details
            it("fails when not given any details") {
                await expect {
                    try await DisplayPictureDownloadJob.run(
                        Job(variant: .displayPictureDownload),
                        using: dependencies
                    )
                }.toEventually(throwError(JobRunnerError.missingRequiredDetails))
            }
            
            // MARK: -- when initialising details
            context("when initialising details") {
                // MARK: ---- for a profile
                context("for a profile") {
                    // MARK: ------ with a target
                    context("with a target") {
                        // MARK: -------- returns nil when given an empty url
                        it("returns nil when given an empty url") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .profile(id: "", url: "", encryptionKey: Data()),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: -------- returns nil when given a url which does not have a file id
                        it("returns nil when given a url which does not have a file id") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .profile(id: "", url: "http://getsession.org", encryptionKey: Data()),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: -------- returns nil when given a url which does not have a file id
                        it("returns nil when given a url which does not have a file id") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .profile(id: "", url: "http://getsession.org", encryptionKey: Data()),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: -------- returns nil when given encryption key data with the wrong length
                        it("returns nil when given encryption key data with the wrong length") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .profile(id: "", url: "http://getsession.org/file/1234/", encryptionKey: Data([1, 2, 3])),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: -------- returns a value when given valid data
                        it("returns a value when given valid data") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .profile(
                                        id: "",
                                        url: "http://getsession.org/file/1234/",
                                        encryptionKey: encryptionKey
                                    ),
                                    timestamp: 0
                                )
                            ).toNot(beNil())
                        }
                    }
                }
                
                // MARK: ---- for a group
                context("for a group") {
                    // MARK: ------ with a target
                    context("with a target") {
                        // MARK: -------- returns nil when given an empty url
                        it("returns nil when given an empty url") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .group(id: "", url: "", encryptionKey: Data()),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: -------- returns nil when given a url which does not have a file id
                        it("returns nil when given a url which does not have a file id") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .group(id: "", url: "http://getsession.org", encryptionKey: Data()),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: -------- returns nil when given a url which does not have a file id
                        it("returns nil when given a url which does not have a file id") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .group(id: "", url: "http://getsession.org", encryptionKey: Data()),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: -------- returns nil when given encryption key data with the wrong length
                        it("returns nil when given encryption key data with the wrong length") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .group(id: "", url: "http://getsession.org/file/1234/", encryptionKey: Data([1, 2, 3])),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: -------- returns a value when given valid data
                        it("returns a value when given valid data") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .group(
                                        id: "",
                                        url: "http://getsession.org/file/1234/",
                                        encryptionKey: encryptionKey
                                    ),
                                    timestamp: 0
                                )
                            ).toNot(beNil())
                        }
                    }
                }
                
                // MARK: ---- for a community
                context("for a community") {
                    // MARK: ------ with a target
                    context("with a target") {
                        // MARK: -------- returns nil when given an empty imageId
                        it("returns nil when given an empty imageId") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .community(imageId: "", roomToken: "", server: "", publicKey: ""),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: -------- returns a value when given valid data
                        it("returns a value when given valid data") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .community(imageId: "12", roomToken: "", server: "", publicKey: ""),
                                    timestamp: 0
                                )
                            ).toNot(beNil())
                        }
                    }
                }
            }
            
            // MARK: -- when hashing
            context("when hashing") {
                @TestState var target: DisplayPictureDownloadJob.Target! = .community(
                    imageId: "12",
                    roomToken: "test",
                    server: "test",
                    publicKey: "test"
                )
                
                // MARK: ---- generates the same hash with the same data
                it("generates the same hash with the same data") {
                    expect(
                        DisplayPictureDownloadJob.Details(
                            target: target,
                            timestamp: 1234
                        )?.hashValue
                    ).to(equal(
                        DisplayPictureDownloadJob.Details(
                            target: target,
                            timestamp: 1234
                        )?.hashValue
                    ))
                }
                
                // MARK: ---- generates a different hash with different data
                it("generates a different hash with different data") {
                    expect(
                        DisplayPictureDownloadJob.Details(
                            target: target,
                            timestamp: 1234
                        )?.hashValue
                    ).toNot(equal(
                        DisplayPictureDownloadJob.Details(
                            target: .community(
                                imageId: "13",
                                roomToken: "test",
                                server: "test",
                                publicKey: "test"
                            ),
                            timestamp: 1234
                        )?.hashValue
                    ))
                }
                
                // MARK: ---- excludes the timestamp when generating the hash value
                it("excludes the timestamp when generating the hash value") {
                    expect(
                        DisplayPictureDownloadJob.Details(
                            target: target,
                            timestamp: 1234
                        )?.hashValue
                    ).to(equal(
                        DisplayPictureDownloadJob.Details(
                            target: target,
                            timestamp: 4321
                        )?.hashValue
                    ))
                }
            }
            
            // MARK: -- uses the streaming download function
            it("uses the streaming download function") {
                profile = Profile(
                    id: "1234",
                    name: "test",
                    nickname: nil,
                    displayPictureUrl: nil,
                    displayPictureEncryptionKey: nil,
                    profileLastUpdated: nil,
                    blocksCommunityMessageRequests: nil,
                    proFeatures: .none,
                    proExpiryUnixTimestampMs: 0,
                    proGenIndexHashHex: nil
                )
                try await mockStorage.writeAsync { db in try profile.insert(db) }
                job = Job(
                    variant: .displayPictureDownload,
                    details: DisplayPictureDownloadJob.Details(
                        target: .profile(
                            id: "1234",
                            url: "http://filev2.getsession.org/file/1234",
                            encryptionKey: encryptionKey
                        ),
                        timestamp: 0
                    )
                )
                
                _ = try? await DisplayPictureDownloadJob.run(job, using: dependencies)
                await mockNetwork
                    .verify {
                        try await $0.download(
                            downloadUrl: "http://filev2.getsession.org/file/1234",
                            stallTimeout: Network.fileDownloadTimeout,
                            requestTimeout: Network.fileDownloadTimeout,
                            overallTimeout: Network.fileDownloadTimeout,
                            partialMinInterval: Network.fileDownloadMinInterval,
                            desiredPathIndex: nil,
                            onProgress: nil
                        )
                    }
                    .wasCalled(exactly: 1, timeout: .milliseconds(100))
            }
            
            // MARK: -- generates a SOGS download request correctly
            it("generates a SOGS download request correctly") {
                mockStorage.write { db in
                    try OpenGroup(
                        server: "testServer",
                        roomToken: "testRoom",
                        publicKey: TestConstants.serverPublicKey,
                        shouldPoll: false,
                        name: "test",
                        imageId: "12",
                        userCount: 0,
                        infoUpdates: 0
                    ).insert(db)
                }
                
                job = Job(
                    variant: .displayPictureDownload,
                    details: DisplayPictureDownloadJob.Details(
                        target: .community(
                            imageId: "12",
                            roomToken: "testRoom",
                            server: "testServer",
                            publicKey: TestConstants.serverPublicKey
                        ),
                        timestamp: 0
                    )
                )
                
                _ = try? await DisplayPictureDownloadJob.run(job, using: dependencies)
                await mockNetwork
                    .verify {
                        try await $0.send(
                            endpoint: Network.SOGS.Endpoint.roomFileIndividual("testRoom", "12"),
                            destination: .server(
                                method: .get,
                                server: "testserver",
                                queryParameters: [:],
                                fragmentParameters: [:],
                                headers: [
                                    HTTPHeader.sogsNonce: "pK6YRtQApl4NhECGizF0Cg==",
                                    HTTPHeader.sogsPubKey: "15\(TestConstants.publicKey)",
                                    HTTPHeader.sogsSignature: "VGVzdFNvZ3NTaWduYXR1cmU=",
                                    HTTPHeader.sogsTimestamp: "1234567890",
                                ],
                                x25519PublicKey: TestConstants.serverPublicKey
                            ),
                            body: nil,
                            category: .file,
                            requestTimeout: Network.fileDownloadTimeout,
                            overallTimeout: nil
                        )
                    }
                    .wasCalled(exactly: 1, timeout: .milliseconds(100))
            }
            
            // MARK: -- checking if a downloaded display picture is valid
            context("checking if a downloaded display picture is valid") {
                @TestState var jobResult: JobExecutionResult?
                
                beforeEach {
                    profile = Profile(
                        id: "1234",
                        name: "test",
                        nickname: nil,
                        displayPictureUrl: nil,
                        displayPictureEncryptionKey: nil,
                        profileLastUpdated: nil,
                        blocksCommunityMessageRequests: nil,
                        proFeatures: .none,
                        proExpiryUnixTimestampMs: 0,
                        proGenIndexHashHex: nil
                    )
                    try await mockStorage.writeAsync { db in try profile.insert(db) }
                    job = try require {
                        Job(
                            variant: .displayPictureDownload,
                            details: DisplayPictureDownloadJob.Details(
                                target: .profile(
                                    id: "1234",
                                    url: "http://getsession.org/file/100/",
                                    encryptionKey: encryptionKey
                                ),
                                timestamp: 1234567891
                            )
                        )
                    }.toNot(beNil())
                }
                
                justBeforeEach {
                    jobResult = try? await DisplayPictureDownloadJob.run(job, using: dependencies)
                }
                
                // MARK: ---- when it fails to decrypt the data
                context("when it fails to decrypt the data") {
                    beforeEach {
                        try await mockCrypto
                            .when { $0.generate(.legacyDecryptedDisplayPicture(data: .any, key: .any)) }
                            .thenReturn(nil)
                    }
                    
                    // MARK: ------ does not save the picture
                    it("does not save the picture") {
                        await mockFileManager
                            .verify { try $0.write(data: .any, toPath: .any) }
                            .wasNotCalled(timeout: .milliseconds(100))
                        await mockImageDataManager
                            .verify { await $0.load(.any) }
                            .wasNotCalled(timeout: .milliseconds(100))
                        await expect {
                            try await mockStorage.readAsync { db in try Profile.fetchOne(db) }
                        }.to(equal(profile))
                    }
                }
                
                // MARK: ---- when it decrypts invalid image data
                context("when it decrypts invalid image data") {
                    beforeEach {
                        try await mockCrypto
                            .when { $0.generate(.legacyDecryptedDisplayPicture(data: .any, key: .any)) }
                            .thenReturn(TestConstants.invalidImageData)
                        await mockImageDataManager.removeMocksFor { $0.isValidImage(at: .any) }
                        try await mockImageDataManager
                            .when { $0.isValidImage(at: .any) }
                            .thenReturn(false)
                    }
                    
                    // MARK: ------ does not save the picture
                    it("does not save the picture") {
                        // The file gets written and then removed when we determine it is invalid
                        await mockFileManager
                            .verify { try $0.write(data: .any, toPath: .any) }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                        await mockFileManager
                            .verify { try $0.removeItem(atPath: "/test/DisplayPictures/5465737448617368") }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                        await mockImageDataManager
                            .verify { await $0.load(.any) }
                            .wasNotCalled(timeout: .milliseconds(100))
                        await expect {
                            try await mockStorage.readAsync { db in try Profile.fetchOne(db) }
                        }.to(equal(profile))
                    }
                }
                
                // MARK: ---- when it fails to write to disk
                context("when it fails to write to disk") {
                    beforeEach {
                        try await mockFileManager
                            .when { try $0.write(data: .any, toPath: .any) }
                            .thenThrow(TestError.mock)
                    }
                    
                    // MARK: ------ does not save the picture
                    it("does not save the picture") {
                        await mockImageDataManager
                            .verify { await $0.load(.any) }
                            .wasNotCalled(timeout: .milliseconds(100))
                        await expect {
                            try await mockStorage.readAsync { db in try Profile.fetchOne(db) }
                        }.to(equal(profile))
                    }
                }
                
                // MARK: ---- writes the file to disk
                it("writes the file to disk") {
                    await mockFileManager
                        .verify {
                            try $0.write(
                                data: TestConstants.validImageData,
                                toPath: "/test/DisplayPictures/5465737448617368"
                            )
                        }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                }
                
                // MARK: ---- adds the image data to the displayPicture cache
                it("adds the image data to the displayPicture cache") {
                    await mockImageDataManager
                        .verify {
                            await $0.load(
                                .url(URL(fileURLWithPath: "/test/DisplayPictures/5465737448617368"))
                            )
                        }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                }
                
                // MARK: ---- successfully completes the job
                it("successfully completes the job") {
                    expect(jobResult).to(equal(.success))
                }
                
                // MARK: ---- for a profile
                context("for a profile") {
                    beforeEach {
                        profile = Profile(
                            id: "1234",
                            name: "test",
                            nickname: nil,
                            displayPictureUrl: "http://getsession.org/file/100/",
                            displayPictureEncryptionKey: encryptionKey,
                            profileLastUpdated: 1234567890,
                            blocksCommunityMessageRequests: nil,
                            proFeatures: .none,
                            proExpiryUnixTimestampMs: 0,
                            proGenIndexHashHex: nil
                        )
                        mockStorage.write { db in
                            _ = try Profile.deleteAll(db)
                            try profile.insert(db)
                        }
                        job = try require {
                            Job(
                                variant: .displayPictureDownload,
                                details: DisplayPictureDownloadJob.Details(
                                    target: .profile(
                                        id: "1234",
                                        url: "http://getsession.org/file/100/",
                                        encryptionKey: encryptionKey
                                    ),
                                    timestamp: 1234567891
                                )
                            )
                        }.toNot(beNil())
                    }
                    
                    // MARK: ------ that does not exist
                    context("that does not exist") {
                        beforeEach {
                            _ = try await mockStorage.writeAsync { db in try Profile.deleteAll(db) }
                        }
                        
                        // MARK: -------- does not save the picture
                        it("does not save the picture") {
                            /// Succeeds as the download has been superseded
                            await expect(jobResult).toEventually(equal(.success))
                            await mockCrypto
                                .verify { $0.generate(.legacyDecryptedDisplayPicture(data: .any, key: .any)) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await mockFileManager
                                .verify { try $0.write(data: .any, toPath: .any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await mockImageDataManager
                                .verify { await $0.load(.any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await expect {
                                try await mockStorage.readAsync { db in try Profile.fetchOne(db) }
                            }.to(beNil())
                        }
                    }
                    
                    // MARK: ------ that has a different encryption key and more recent update
                    context("that has a different encryption key and more recent update") {
                        beforeEach {
                            _ = try await mockStorage.writeAsync { db in
                                try Profile
                                    .updateAll(
                                        db,
                                        Profile.Columns.displayPictureEncryptionKey.set(to: Data([1, 2, 3])),
                                        Profile.Columns.profileLastUpdated.set(to: 9999999999)
                                    )
                            }
                        }
                        
                        // MARK: -------- does not save the picture
                        it("does not save the picture") {
                            await mockCrypto
                                .verify { $0.generate(.legacyDecryptedDisplayPicture(data: .any, key: .any)) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await mockFileManager
                                .verify { try $0.write(data: .any, toPath: .any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await mockImageDataManager
                                .verify { await $0.load(.any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await expect {
                                try await mockStorage.readAsync { db in try Profile.fetchOne(db) }
                            }.toNot(equal(
                                Profile(
                                    id: "1234",
                                    name: "test",
                                    nickname: nil,
                                    displayPictureUrl: "http://getsession.org/file/100/",
                                    displayPictureEncryptionKey: encryptionKey,
                                    profileLastUpdated: 1234567891,
                                    blocksCommunityMessageRequests: nil,
                                    proFeatures: .none,
                                    proExpiryUnixTimestampMs: 0,
                                    proGenIndexHashHex: nil
                                )
                            ))
                        }
                    }
                    
                    // MARK: ------ that has a different url and more recent update
                    context("that has a different url and more recent update") {
                        beforeEach {
                            _ = try await mockStorage.writeAsync { db in
                                try Profile
                                    .updateAll(
                                        db,
                                        Profile.Columns.displayPictureUrl.set(to: "testUrl"),
                                        Profile.Columns.profileLastUpdated.set(to: 9999999999)
                                    )
                            }
                        }
                        
                        // MARK: -------- does not save the picture
                        it("does not save the picture") {
                            await mockCrypto
                                .verify {
                                    $0.generate(.legacyDecryptedDisplayPicture(data: .any, key: .any))
                                }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await mockFileManager
                                .verify { try $0.write(data: .any, toPath: .any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await mockImageDataManager
                                .verify { await $0.load(.any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await expect {
                                try await mockStorage.readAsync { db in try Profile.fetchOne(db) }
                            }.toNot(equal(
                                Profile(
                                    id: "1234",
                                    name: "test",
                                    nickname: nil,
                                    displayPictureUrl: "http://getsession.org/file/100/",
                                    displayPictureEncryptionKey: encryptionKey,
                                    profileLastUpdated: 1234567891,
                                    blocksCommunityMessageRequests: nil,
                                    proFeatures: .none,
                                    proExpiryUnixTimestampMs: 0,
                                    proGenIndexHashHex: nil
                                )
                            ))
                        }
                    }
                    
                    // MARK: ------ that has a more recent update but the same url and encryption key
                    context("that has a more recent update but the same url and encryption key") {
                        beforeEach {
                            _ = try await mockStorage.writeAsync { db in
                                try Profile
                                    .updateAll(
                                        db,
                                        Profile.Columns.profileLastUpdated.set(to: 9999999999)
                                    )
                            }
                        }
                        
                        // MARK: -------- saves the picture
                        it("saves the picture") {
                            await mockCrypto
                                .verify {
                                    $0.generate(.legacyDecryptedDisplayPicture(data: .any, key: .any))
                                }
                                .wasCalled(exactly: 1, timeout: .milliseconds(100))
                            await mockFileManager
                                .verify {
                                    try $0.write(
                                        data: TestConstants.validImageData,
                                        toPath: "/test/DisplayPictures/5465737448617368"
                                    )
                                }
                                .wasCalled(exactly: 1, timeout: .milliseconds(100))
                            
                            await mockImageDataManager
                                .verify {
                                    await $0.load(
                                        .url(URL(fileURLWithPath: "/test/DisplayPictures/5465737448617368"))
                                    )
                                }
                                .wasCalled(exactly: 1, timeout: .milliseconds(100))
                            await expect {
                                try await mockStorage.readAsync { db in try Profile.fetchOne(db) }
                            }.to(equal(
                                Profile(
                                    id: "1234",
                                    name: "test",
                                    nickname: nil,
                                    displayPictureUrl: "http://getsession.org/file/100/",
                                    displayPictureEncryptionKey: encryptionKey,
                                    profileLastUpdated: 1234567891,
                                    blocksCommunityMessageRequests: nil,
                                    proFeatures: .none,
                                    proExpiryUnixTimestampMs: 0,
                                    proGenIndexHashHex: nil
                                )
                            ))
                        }
                    }
                    
                    // MARK: ------ updates the database values
                    it("updates the database values") {
                        await expect {
                            try await mockStorage.readAsync { db in try Profile.fetchOne(db) }
                        }.to(equal(
                            Profile(
                                id: "1234",
                                name: "test",
                                nickname: nil,
                                displayPictureUrl: "http://getsession.org/file/100/",
                                displayPictureEncryptionKey: encryptionKey,
                                profileLastUpdated: 1234567891,
                                blocksCommunityMessageRequests: nil,
                                proFeatures: .none,
                                proExpiryUnixTimestampMs: 0,
                                proGenIndexHashHex: nil
                            )
                        ))
                    }
                }
                
                // MARK: ---- for a group
                context("for a group") {
                    beforeEach {
                        group = ClosedGroup(
                            threadId: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece",
                            name: "TestGroup",
                            groupDescription: nil,
                            formationTimestamp: 1234567890,
                            displayPictureUrl: "http://getsession.org/file/100/",
                            displayPictureEncryptionKey: encryptionKey,
                            shouldPoll: true,
                            groupIdentityPrivateKey: nil,
                            authData: Data([1, 2, 3]),
                            invited: false
                        )
                        try await mockStorage.writeAsync { db in
                            _ = try ClosedGroup.deleteAll(db)
                            try SessionThread.upsert(
                                db,
                                id: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece",
                                variant: .group,
                                values: SessionThread.TargetValues(
                                    creationDateTimestamp: .setTo(1234567890),
                                    shouldBeVisible: .setTo(true)
                                ),
                                using: dependencies
                            ).upsert(db)
                            try group.insert(db)
                        }
                        job = try require {
                            Job(
                                variant: .displayPictureDownload,
                                details: DisplayPictureDownloadJob.Details(
                                    target: .group(
                                        id: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece",
                                        url: "http://getsession.org/file/100/",
                                        encryptionKey: encryptionKey
                                    ),
                                    timestamp: 1234567891
                                )
                            )
                        }.toNot(beNil())
                    }
                    
                    // MARK: ------ that does not exist
                    context("that does not exist") {
                        beforeEach {
                            _ = try await mockStorage.writeAsync { db in try ClosedGroup.deleteAll(db) }
                        }
                        
                        // MARK: -------- does not save the picture
                        it("does not save the picture") {
                            await mockCrypto
                                .verify {
                                    $0.generate(.legacyDecryptedDisplayPicture(data: .any, key: .any))
                                }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await mockFileManager
                                .verify { try $0.write(data: .any, toPath: .any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await mockImageDataManager
                                .verify { await $0.load(.any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await expect {
                                try await mockStorage.readAsync { db in try ClosedGroup.fetchOne(db) }
                            }.to(beNil())
                        }
                    }
                    
                    // MARK: ------ that has a different encryption key and more recent update
                    context("that has a different encryption key and more recent update") {
                        beforeEach {
                            _ = try await mockStorage.writeAsync { db in
                                try ClosedGroup
                                    .updateAll(
                                        db,
                                        ClosedGroup.Columns.displayPictureEncryptionKey.set(to: Data([1, 2, 3]))
                                    )
                            }
                        }
                        
                        // MARK: -------- does not save the picture
                        it("does not save the picture") {
                            await mockCrypto
                                .verify {
                                    $0.generate(.legacyDecryptedDisplayPicture(data: .any, key: .any))
                                }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await mockFileManager
                                .verify { try $0.write(data: .any, toPath: .any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await mockImageDataManager
                                .verify { await $0.load(.any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await expect {
                                try await mockStorage.readAsync { db in try ClosedGroup.fetchOne(db) }
                            }.toNot(equal(
                                ClosedGroup(
                                    threadId: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece",
                                    name: "TestGroup",
                                    groupDescription: nil,
                                    formationTimestamp: 1234567890,
                                    displayPictureUrl: "http://getsession.org/file/100/",
                                    displayPictureEncryptionKey: encryptionKey,
                                    shouldPoll: true,
                                    groupIdentityPrivateKey: nil,
                                    authData: Data([1, 2, 3]),
                                    invited: false
                                )
                            ))
                        }
                    }
                    
                    // MARK: ------ that has a different url and more recent update
                    context("that has a different url and more recent update") {
                        beforeEach {
                            _ = try await mockStorage.writeAsync { db in
                                try ClosedGroup
                                    .updateAll(
                                        db,
                                        ClosedGroup.Columns.displayPictureUrl.set(to: "testUrl")
                                    )
                            }
                        }
                        
                        // MARK: -------- does not save the picture
                        it("does not save the picture") {
                            await mockCrypto
                                .verify {
                                    $0.generate(.legacyDecryptedDisplayPicture(data: .any, key: .any))
                                }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await mockFileManager
                                .verify { try $0.write(data: .any, toPath: .any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await mockImageDataManager
                                .verify { await $0.load(.any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await expect {
                                try await mockStorage.readAsync { db in try ClosedGroup.fetchOne(db) }
                            }.toNot(equal(
                                ClosedGroup(
                                    threadId: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece",
                                    name: "TestGroup",
                                    groupDescription: nil,
                                    formationTimestamp: 1234567890,
                                    displayPictureUrl: "http://getsession.org/file/100/",
                                    displayPictureEncryptionKey: encryptionKey,
                                    shouldPoll: true,
                                    groupIdentityPrivateKey: nil,
                                    authData: Data([1, 2, 3]),
                                    invited: false
                                )
                            ))
                        }
                    }
                    
                    // MARK: ------ updates the database values
                    it("updates the database values") {
                        await expect {
                            try await mockStorage.readAsync { db in try ClosedGroup.fetchOne(db) }
                        }.to(equal(
                            ClosedGroup(
                                threadId: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece",
                                name: "TestGroup",
                                groupDescription: nil,
                                formationTimestamp: 1234567890,
                                displayPictureUrl: "http://getsession.org/file/100/",
                                displayPictureEncryptionKey: encryptionKey,
                                shouldPoll: true,
                                groupIdentityPrivateKey: nil,
                                authData: Data([1, 2, 3]),
                                invited: false
                            )
                        ))
                    }
                }
                
                // MARK: ---- for a community
                context("for a community") {
                    beforeEach {
                        community = OpenGroup(
                            server: "testServer",
                            roomToken: "testRoom",
                            publicKey: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece",
                            shouldPoll: true,
                            name: "name",
                            imageId: "100",
                            userCount: 1,
                            infoUpdates: 1,
                            displayPictureOriginalUrl: nil
                        )
                        try await mockStorage.writeAsync { db in
                            _ = try OpenGroup.deleteAll(db)
                            try SessionThread.upsert(
                                db,
                                id: OpenGroup.idFor(roomToken: "testRoom", server: "testServer"),
                                variant: .community,
                                values: SessionThread.TargetValues(
                                    creationDateTimestamp: .setTo(1234567890),
                                    shouldBeVisible: .setTo(true)
                                ),
                                using: dependencies
                            ).upsert(db)
                            try community.insert(db)
                        }
                        job = try require {
                            Job(
                                variant: .displayPictureDownload,
                                details: DisplayPictureDownloadJob.Details(
                                    target: .community(
                                        imageId: "100",
                                        roomToken: "testRoom",
                                        server: "testServer",
                                        publicKey: TestConstants.serverPublicKey
                                    ),
                                    timestamp: 1234567891
                                )
                            )
                        }.toNot(beNil())
                    }
                    
                    // MARK: ------ that does not exist
                    context("that does not exist") {
                        beforeEach {
                            mockStorage.write { db in try OpenGroup.deleteAll(db) }
                        }
                        
                        // MARK: -------- does not save the picture
                        it("does not save the picture") {
                            await mockFileManager
                                .verify { try $0.write(data: .any, toPath: .any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await mockImageDataManager
                                .verify { await $0.load(.any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await expect {
                                try await mockStorage.readAsync { db in try OpenGroup.fetchOne(db) }
                            }.to(beNil())
                        }
                    }
                    
                    // MARK: ------ that has a different imageId
                    context("that has a different imageId") {
                        beforeEach {
                            _ = try await mockStorage.writeAsync { db in
                                try OpenGroup
                                    .updateAll(
                                        db,
                                        OpenGroup.Columns.imageId.set(to: "101")
                                    )
                            }
                        }
                        
                        // MARK: -------- does not save the picture
                        it("does not save the picture") {
                            await mockFileManager
                                .verify { $0.createFile(atPath: .any, contents: .any, attributes: .any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await mockImageDataManager
                                .verify { await $0.load(.any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            await expect {
                                try await mockStorage.readAsync { db in try OpenGroup.fetchOne(db) }
                            }.toNot(equal(
                                OpenGroup(
                                    server: "testServer",
                                    roomToken: "testRoom",
                                    publicKey: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece",
                                    shouldPoll: true,
                                    name: "name",
                                    imageId: "100",
                                    userCount: 1,
                                    infoUpdates: 1
                                )
                            ))
                        }
                    }
                    
                    // MARK: ------ that has the same imageId
                    context("that has the same imageId") {
                        beforeEach {
                            _ = try await mockStorage.writeAsync { db in
                                try OpenGroup
                                    .updateAll(
                                        db,
                                        OpenGroup.Columns.imageId.set(to: "100")
                                    )
                            }
                        }
                        
                        // MARK: -------- saves the picture
                        it("saves the picture") {
                            await mockFileManager
                                .verify {
                                    try $0.write(
                                        data: TestConstants.validImageData,
                                        toPath: "tmpFile"
                                    )
                                }
                                .wasCalled(exactly: 1, timeout: .milliseconds(100))
                            await mockImageDataManager
                                .verify {
                                    await $0.load(
                                        .url(URL(fileURLWithPath: "/test/DisplayPictures/5465737448617368"))
                                    )
                                }
                                .wasCalled(exactly: 1, timeout: .milliseconds(100))
                            await mockFileManager
                                .verify {
                                    try $0.moveItem(
                                        atPath: "tmpFile",
                                        toPath: "/test/DisplayPictures/5465737448617368"
                                    )
                                }
                                .wasCalled(exactly: 1, timeout: .milliseconds(100))
                            await expect {
                                try await mockStorage.readAsync { db in try OpenGroup.fetchOne(db) }
                            }.to(equal(
                                OpenGroup(
                                    server: "testServer",
                                    roomToken: "testRoom",
                                    publicKey: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece",
                                    shouldPoll: true,
                                    name: "name",
                                    imageId: "100",
                                    userCount: 1,
                                    infoUpdates: 1,
                                    displayPictureOriginalUrl: "testserver/room/testRoom/file/100"
                                )
                            ))
                        }
                    }
                    
                    // MARK: ------ updates the database values
                    it("updates the database values") {
                        expect(mockStorage.read { db in try OpenGroup.fetchOne(db) })
                            .to(equal(
                                OpenGroup(
                                    server: "testServer",
                                    roomToken: "testRoom",
                                    publicKey: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece",
                                    shouldPoll: true,
                                    name: "name",
                                    imageId: "100",
                                    userCount: 1,
                                    infoUpdates: 1,
                                    displayPictureOriginalUrl: "testserver/room/testRoom/file/100"
                                )
                            ))
                    }
                }
            }
        }
    }
}
