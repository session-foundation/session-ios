// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

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
        @TestState var imageData: Data! = Data(
            hex: "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c" +
            "489000000017352474200aece1ce90000000d49444154185763f8cfc0f01f0005000" +
            "1ffa65c9b5d0000000049454e44ae426082"
        )
        @TestState var encryptionKey: Data! = Data(hex: "c8e52eb1016702a663ac9a1ab5522daa128ab40762a514de271eddf598e3b8d4")
        @TestState var encryptedData: Data! = Data(
            hex: "778921bdd0e432227b53ee49c23421aeb796b7e5663468ff79daffb1af08cd1" +
            "a68343377fe05ab01917ce0fb8732c746a60f157f7798cdf999364b37ff9016ab2fe" +
            "673120e153a5cb6b869380744d493068ebc418266d6596d728cfc60b30662a089376" +
            "f2761e3bb6ee837a26b24b5"
        )
        @TestState var mockNetwork: MockNetwork! = .create(using: dependencies)
        @TestState var mockFileManager: MockFileManager! = .create(using: dependencies)
        @TestState var mockCrypto: MockCrypto! = .create(using: dependencies)
        @TestState var mockImageDataManager: MockImageDataManager! = .create(using: dependencies)
        @TestState var mockGeneralCache: MockGeneralCache! = .create(using: dependencies)
        
        beforeEach {
            try await mockGeneralCache.defaultInitialSetup()
            dependencies.set(cache: .general, to: mockGeneralCache)
            
            try await mockLibSessionCache.defaultInitialSetup()
            dependencies.set(cache: .libSession, to: mockLibSessionCache)
            
            try await mockFileManager.defaultInitialSetup()
            dependencies.set(singleton: .fileManager, to: mockFileManager)
            
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            try await mockStorage.writeAsync { db in
                try Identity(variant: .x25519PublicKey, data: Data(hex: TestConstants.publicKey)).insert(db)
                try Identity(variant: .x25519PrivateKey, data: Data(hex: TestConstants.privateKey)).insert(db)
                try Identity(variant: .ed25519PublicKey, data: Data(hex: TestConstants.edPublicKey)).insert(db)
                try Identity(variant: .ed25519SecretKey, data: Data(hex: TestConstants.edSecretKey)).insert(db)
            }
            dependencies.set(singleton: .storage, to: mockStorage)
            
            try await mockCrypto.when { $0.generate(.uuid()) }.thenReturn(UUID(uuidString: "00000000-0000-0000-0000-000000001234"))
            try await mockCrypto
                .when { $0.generate(.decryptedDataDisplayPicture(data: .any, key: .any)) }
                .thenReturn(imageData)
            try await mockCrypto.when { $0.generate(.hash(message: .any, length: .any)) }.thenReturn("TestHash".bytes)
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
            dependencies.set(singleton: .crypto, to: mockCrypto)
            
            try await mockNetwork.defaultInitialSetup(using: dependencies)
            await mockNetwork.removeRequestMocks()
            try await mockNetwork
                .when {
                    $0.send(
                        endpoint: MockEndpoint.any,
                        destination: .any,
                        body: .any,
                        category: .any,
                        requestTimeout: .any,
                        overallTimeout: .any
                    )
                }
                .thenReturn(MockNetwork.response(data: encryptedData))
            dependencies.set(singleton: .network, to: mockNetwork)
            
            try await mockImageDataManager
                .when { await $0.load(.any) }
                .thenReturn(nil)
            dependencies.set(singleton: .imageDataManager, to: mockImageDataManager)
        }
        
        // MARK: - a DisplayPictureDownloadJob
        describe("a DisplayPictureDownloadJob") {
            // MARK: -- fails when not given any details
            it("fails when not given any details") {
                job = Job(variant: .displayPictureDownload)
                
                var error: Error? = nil
                var permanentFailure: Bool = false
                
                DisplayPictureDownloadJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in },
                    failure: { _, runError, runPermanentFailure in
                        error = runError
                        permanentFailure = runPermanentFailure
                    },
                    deferred: { _ in },
                    using: dependencies
                )
                
                expect(error).to(matchError(JobRunnerError.missingRequiredDetails))
                expect(permanentFailure).to(beTrue())
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
                                    target: .profile(id: "", url: "http://oxen.io", encryptionKey: Data()),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: -------- returns nil when given a url which does not have a file id
                        it("returns nil when given a url which does not have a file id") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .profile(id: "", url: "http://oxen.io", encryptionKey: Data()),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: -------- returns nil when given encryption key data with the wrong length
                        it("returns nil when given encryption key data with the wrong length") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .profile(id: "", url: "http://oxen.io/1234/", encryptionKey: Data([1, 2, 3])),
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
                                        url: "http://oxen.io/1234/",
                                        encryptionKey: encryptionKey
                                    ),
                                    timestamp: 0
                                )
                            ).toNot(beNil())
                        }
                    }
                    
                    // MARK: ------ with an owner
                    context("with an owner") {
                        // MARK: -------- returns nil when given a null url
                        it("returns nil when given a null url") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    owner: .user(
                                        Profile(
                                            id: "1234",
                                            name: "test",
                                            displayPictureUrl: nil,
                                            displayPictureEncryptionKey: encryptionKey
                                        )
                                    )
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: -------- returns nil when given a null encryption key
                        it("returns nil when given a null encryption key") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    owner: .user(
                                        Profile(
                                            id: "1234",
                                            name: "test",
                                            displayPictureUrl: "http://oxen.io/1234/",
                                            displayPictureEncryptionKey: nil
                                        )
                                    )
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: -------- returns a value when given valid data
                        it("returns a value when given valid data") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    owner: .user(
                                        Profile(
                                            id: "1234",
                                            name: "test",
                                            displayPictureUrl: "http://oxen.io/1234/",
                                            displayPictureEncryptionKey: encryptionKey
                                        )
                                    )
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
                                    target: .group(id: "", url: "http://oxen.io", encryptionKey: Data()),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: -------- returns nil when given a url which does not have a file id
                        it("returns nil when given a url which does not have a file id") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .group(id: "", url: "http://oxen.io", encryptionKey: Data()),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: -------- returns nil when given encryption key data with the wrong length
                        it("returns nil when given encryption key data with the wrong length") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .group(id: "", url: "http://oxen.io/1234/", encryptionKey: Data([1, 2, 3])),
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
                                        url: "http://oxen.io/1234/",
                                        encryptionKey: encryptionKey
                                    ),
                                    timestamp: 0
                                )
                            ).toNot(beNil())
                        }
                    }
                    
                    // MARK: ------ with an owner
                    context("with an owner") {
                        // MARK: -------- returns nil when given a null url
                        it("returns nil when given a null url") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    owner: .group(
                                        ClosedGroup(
                                            threadId: "1234",
                                            name: "test",
                                            formationTimestamp: 0,
                                            displayPictureUrl: nil,
                                            displayPictureEncryptionKey: encryptionKey,
                                            shouldPoll: nil,
                                            invited: nil
                                        )
                                    )
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: -------- returns nil when given a null encryption key
                        it("returns nil when given a null encryption key") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    owner: .group(
                                        ClosedGroup(
                                            threadId: "1234",
                                            name: "test",
                                            formationTimestamp: 0,
                                            displayPictureUrl: "http://oxen.io/1234/",
                                            displayPictureEncryptionKey: nil,
                                            shouldPoll: nil,
                                            invited: nil
                                        )
                                    )
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: -------- returns a value when given valid data
                        it("returns a value when given valid data") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    owner: .group(
                                        ClosedGroup(
                                            threadId: "1234",
                                            name: "test",
                                            formationTimestamp: 0,
                                            displayPictureUrl: "http://oxen.io/1234/",
                                            displayPictureEncryptionKey: encryptionKey,
                                            shouldPoll: nil,
                                            invited: nil
                                        )
                                    )
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
                                    target: .community(imageId: "", roomToken: "", server: ""),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: -------- returns a value when given valid data
                        it("returns a value when given valid data") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .community(imageId: "12", roomToken: "", server: ""),
                                    timestamp: 0
                                )
                            ).toNot(beNil())
                        }
                    }
                    
                    // MARK: ------ with an owner
                    context("with an owner") {
                        // MARK: -------- returns nil when given an empty imageId
                        it("returns nil when given an empty imageId") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    owner: .community(
                                        OpenGroup(
                                            server: "testServer",
                                            roomToken: "testRoom",
                                            publicKey: "1234",
                                            isActive: false,
                                            name: "test",
                                            imageId: nil,
                                            userCount: 0,
                                            infoUpdates: 0
                                        )
                                    )
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: -------- returns a value when given valid data
                        it("returns a value when given valid data") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    owner: .community(
                                        OpenGroup(
                                            server: "testServer",
                                            roomToken: "testRoom",
                                            publicKey: "1234",
                                            isActive: false,
                                            name: "test",
                                            imageId: "12",
                                            userCount: 0,
                                            infoUpdates: 0
                                        )
                                    )
                                )
                            ).toNot(beNil())
                        }
                    }
                }
            }
            
            // MARK: -- when hashing
            context("when hashing") {
                // MARK: ---- generates the same hash with the same data
                it("generates the same hash with the same data") {
                    expect(
                        DisplayPictureDownloadJob.Details(
                            target: .community(imageId: "12", roomToken: "test", server: "test"),
                            timestamp: 1234
                        )?.hashValue
                    ).to(equal(
                        DisplayPictureDownloadJob.Details(
                            target: .community(imageId: "12", roomToken: "test", server: "test"),
                            timestamp: 1234
                        )?.hashValue
                    ))
                }
                
                // MARK: ---- generates a different hash with different data
                it("generates a different hash with different data") {
                    expect(
                        DisplayPictureDownloadJob.Details(
                            target: .community(imageId: "12", roomToken: "test", server: "test"),
                            timestamp: 1234
                        )?.hashValue
                    ).toNot(equal(
                        DisplayPictureDownloadJob.Details(
                            target: .community(imageId: "13", roomToken: "test", server: "test"),
                            timestamp: 1234
                        )?.hashValue
                    ))
                }
                
                // MARK: ---- excludes the timestamp when generating the hash value
                it("excludes the timestamp when generating the hash value") {
                    expect(
                        DisplayPictureDownloadJob.Details(
                            target: .community(imageId: "12", roomToken: "test", server: "test"),
                            timestamp: 1234
                        )?.hashValue
                    ).to(equal(
                        DisplayPictureDownloadJob.Details(
                            target: .community(imageId: "12", roomToken: "test", server: "test"),
                            timestamp: 4321
                        )?.hashValue
                    ))
                }
            }
            
            // MARK: -- generates a FileServer download request correctly
            it("generates a FileServer download request correctly") {
                job = Job(
                    variant: .displayPictureDownload,
                    shouldBeUnique: true,
                    details: DisplayPictureDownloadJob.Details(
                        target: .profile(
                            id: "",
                            url: "http://filev2.getsession.org/file/1234",
                            encryptionKey: encryptionKey
                        ),
                        timestamp: 0
                    )
                )
                let expectedRequest: Network.PreparedRequest<Data> = try Network.FileServer.preparedDownload(
                    url: URL(string: "http://filev2.getsession.org/file/1234")!,
                    using: dependencies
                )
                
                DisplayPictureDownloadJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in },
                    failure: { _, _, _ in },
                    deferred: { _ in },
                    using: dependencies
                )
                
                await mockNetwork
                    .verify {
                        $0.send(
                            endpoint: expectedRequest.endpoint,
                            destination: expectedRequest.destination,
                            body: expectedRequest.body,
                            category: .download,
                            requestTimeout: expectedRequest.requestTimeout,
                            overallTimeout: expectedRequest.overallTimeout
                        )
                    }
                    .wasCalled(exactly: 1)
            }
            
            // MARK: -- generates a SOGS download request correctly
            it("generates a SOGS download request correctly") {
                mockStorage.write { db in
                    try OpenGroup(
                        server: "testServer",
                        roomToken: "testRoom",
                        publicKey: TestConstants.serverPublicKey,
                        isActive: false,
                        name: "test",
                        userCount: 0,
                        infoUpdates: 0
                    ).insert(db)
                }
                
                job = Job(
                    variant: .displayPictureDownload,
                    shouldBeUnique: true,
                    details: DisplayPictureDownloadJob.Details(
                        target: .community(
                            imageId: "12",
                            roomToken: "testRoom",
                            server: "testServer"
                        ),
                        timestamp: 0
                    )
                )
                let expectedRequest: Network.PreparedRequest<Data> = mockStorage.read { db in
                    try Network.SOGS.preparedDownload(
                        fileId: "12",
                        roomToken: "testRoom",
                        authMethod: Authentication.community(
                            info: LibSession.OpenGroupCapabilityInfo(
                                roomToken: "",
                                server: "testserver",
                                publicKey: TestConstants.serverPublicKey,
                                capabilities: []
                            ),
                            forceBlinded: false
                        ),
                        using: dependencies
                    )
                }!
                
                DisplayPictureDownloadJob.run(
                    job,
                    scheduler: DispatchQueue.main,
                    success: { _, _ in },
                    failure: { _, _, _ in },
                    deferred: { _ in },
                    using: dependencies
                )
                
                await mockNetwork
                    .verify {
                        $0.send(
                            endpoint: expectedRequest.endpoint,
                            destination: expectedRequest.destination,
                            body: expectedRequest.body,
                            category: .download,
                            requestTimeout: expectedRequest.requestTimeout,
                            overallTimeout: expectedRequest.overallTimeout
                        )
                    }
                    .wasCalled(exactly: 1)
            }
            
            // MARK: -- checking if a downloaded display picture is valid
            context("checking if a downloaded display picture is valid") {
                @TestState var jobResult: JobRunner.JobResult! = .notFound
                
                beforeEach {
                    profile = Profile(
                        id: "1234",
                        name: "test",
                        displayPictureUrl: nil,
                        displayPictureEncryptionKey: nil,
                        displayPictureLastUpdated: nil
                    )
                    mockStorage.write { db in try profile.insert(db) }
                    job = Job(
                        variant: .displayPictureDownload,
                        shouldBeUnique: true,
                        details: DisplayPictureDownloadJob.Details(
                            target: .profile(
                                id: "1234",
                                url: "http://oxen.io/100/",
                                encryptionKey: encryptionKey
                            ),
                            timestamp: 1234567891
                        )
                    )
                }
                
                justBeforeEach {
                    DisplayPictureDownloadJob.run(
                        job,
                        scheduler: DispatchQueue.main,
                        success: { _, _ in jobResult = .succeeded },
                        failure: { _, error, permanent in jobResult = .failed(error, permanent) },
                        deferred: { _ in jobResult = .deferred },
                        using: dependencies
                    )
                }
                
                // MARK: ---- when it fails to decrypt the data
                context("when it fails to decrypt the data") {
                    beforeEach {
                        try await mockCrypto
                            .when { $0.generate(.decryptedDataDisplayPicture(data: .any, key: .any)) }
                            .thenReturn(nil)
                    }
                    
                    // MARK: ------ does not save the picture
                    it("does not save the picture") {
                        await mockFileManager
                            .verify { $0.createFile(atPath: .any, contents: .any, attributes: .any) }
                            .wasNotCalled()
                        await mockImageDataManager
                            .verify { await $0.load(.any) }
                            .wasNotCalled(timeout: .milliseconds(100))
                        expect(mockStorage.read { db in try Profile.fetchOne(db) }).to(equal(profile))
                    }
                }
                
                // MARK: ---- when it decrypts invalid image data
                context("when it decrypts invalid image data") {
                    beforeEach {
                        try await mockCrypto
                            .when { $0.generate(.decryptedDataDisplayPicture(data: .any, key: .any)) }
                            .thenReturn(Data([1, 2, 3]))
                    }
                    
                    // MARK: ------ does not save the picture
                    it("does not save the picture") {
                        await mockFileManager
                            .verify { $0.createFile(atPath: .any, contents: .any, attributes: .any) }
                            .wasNotCalled()
                        await mockImageDataManager
                            .verify { await $0.load(.any) }
                            .wasNotCalled(timeout: .milliseconds(100))
                        expect(mockStorage.read { db in try Profile.fetchOne(db) }).to(equal(profile))
                    }
                }
                
                // MARK: ---- when it fails to write to disk
                context("when it fails to write to disk") {
                    beforeEach {
                        try await mockFileManager
                            .when { $0.createFile(atPath: .any, contents: .any, attributes: .any) }
                            .thenReturn(false)
                    }
                    
                    // MARK: ------ does not save the picture
                    it("does not save the picture") {
                        await mockImageDataManager
                            .verify { await $0.load(.any) }
                            .wasNotCalled(timeout: .milliseconds(100))
                        expect(mockStorage.read { db in try Profile.fetchOne(db) }).to(equal(profile))
                    }
                }
                
                // MARK: ---- writes the file to disk
                it("writes the file to disk") {
                    await mockFileManager
                        .verify {
                            $0.createFile(
                                atPath: "/test/DisplayPictures/5465737448617368",
                                contents: imageData,
                                attributes: nil
                            )
                        }
                        .wasCalled(exactly: 1)
                }
                
                // MARK: ---- adds the image data to the displayPicture cache
                it("adds the image data to the displayPicture cache") {
                    await mockImageDataManager
                        .verify { await $0.load(.url(URL(fileURLWithPath: "/test/DisplayPictures/5465737448617368"))) }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                }
                
                // MARK: ---- successfully completes the job
                it("successfully completes the job") {
                    expect(jobResult).to(equal(.succeeded))
                }
                
                // MARK: ---- for a profile
                context("for a profile") {
                    beforeEach {
                        profile = Profile(
                            id: "1234",
                            name: "test",
                            displayPictureUrl: "http://oxen.io/100/",
                            displayPictureEncryptionKey: encryptionKey,
                            displayPictureLastUpdated: 1234567890
                        )
                        mockStorage.write { db in
                            _ = try Profile.deleteAll(db)
                            try profile.insert(db)
                        }
                        job = Job(
                            variant: .displayPictureDownload,
                            shouldBeUnique: true,
                            details: DisplayPictureDownloadJob.Details(
                                target: .profile(
                                    id: "1234",
                                    url: "http://oxen.io/100/",
                                    encryptionKey: encryptionKey
                                ),
                                timestamp: 1234567891
                            )
                        )
                    }
                    
                    // MARK: ------ that does not exist
                    context("that does not exist") {
                        beforeEach {
                            mockStorage.write { db in try Profile.deleteAll(db) }
                        }
                        
                        // MARK: -------- does not save the picture
                        it("does not save the picture") {
                            await mockCrypto
                                .verify { $0.generate(.decryptedDataDisplayPicture(data: .any, key: .any)) }
                                .wasNotCalled()
                            await mockFileManager
                                .verify { $0.createFile(atPath: .any, contents: .any, attributes: .any) }
                                .wasNotCalled()
                            await mockImageDataManager
                                .verify { await $0.load(.any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            expect(mockStorage.read { db in try Profile.fetchOne(db) }).to(beNil())
                        }
                    }
                    
                    // MARK: ------ that has a different encryption key and more recent update
                    context("that has a different encryption key and more recent update") {
                        beforeEach {
                            mockStorage.write { db in
                                try Profile
                                    .updateAll(
                                        db,
                                        Profile.Columns.displayPictureEncryptionKey.set(to: Data([1, 2, 3])),
                                        Profile.Columns.displayPictureLastUpdated.set(to: 9999999999)
                                    )
                            }
                        }
                        
                        // MARK: -------- does not save the picture
                        it("does not save the picture") {
                            await mockCrypto
                                .verify { $0.generate(.decryptedDataDisplayPicture(data: .any, key: .any)) }
                                .wasNotCalled()
                            await mockFileManager
                                .verify { $0.createFile(atPath: .any, contents: .any, attributes: .any) }
                                .wasNotCalled()
                            await mockImageDataManager
                                .verify { await $0.load(.any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            expect(mockStorage.read { db in try Profile.fetchOne(db) })
                                .toNot(equal(
                                    Profile(
                                        id: "1234",
                                        name: "test",
                                        displayPictureUrl: "http://oxen.io/100/",
                                        displayPictureEncryptionKey: encryptionKey,
                                        displayPictureLastUpdated: 1234567891
                                    )
                                ))
                        }
                    }
                    
                    // MARK: ------ that has a different url and more recent update
                    context("that has a different url and more recent update") {
                        beforeEach {
                            mockStorage.write { db in
                                try Profile
                                    .updateAll(
                                        db,
                                        Profile.Columns.displayPictureUrl.set(to: "testUrl"),
                                        Profile.Columns.displayPictureLastUpdated.set(to: 9999999999)
                                    )
                            }
                        }
                        
                        // MARK: -------- does not save the picture
                        it("does not save the picture") {
                            await mockCrypto
                                .verify { $0.generate(.decryptedDataDisplayPicture(data: .any, key: .any)) }
                                .wasNotCalled()
                            await mockFileManager
                                .verify { $0.createFile(atPath: .any, contents: .any, attributes: .any) }
                                .wasNotCalled()
                            await mockImageDataManager
                                .verify { await $0.load(.any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            expect(mockStorage.read { db in try Profile.fetchOne(db) })
                                .toNot(equal(
                                    Profile(
                                        id: "1234",
                                        name: "test",
                                        displayPictureUrl: "http://oxen.io/100/",
                                        displayPictureEncryptionKey: encryptionKey,
                                        displayPictureLastUpdated: 1234567891
                                    )
                                ))
                        }
                    }
                    
                    // MARK: ------ that has a more recent update but the same url and encryption key
                    context("that has a more recent update but the same url and encryption key") {
                        beforeEach {
                            mockStorage.write { db in
                                try Profile
                                    .updateAll(
                                        db,
                                        Profile.Columns.displayPictureLastUpdated.set(to: 9999999999)
                                    )
                            }
                        }
                        
                        // MARK: -------- saves the picture
                        it("saves the picture") {
                            await mockCrypto
                                .verify { $0.generate(.decryptedDataDisplayPicture(data: .any, key: .any)) }
                                .wasCalled(exactly: 1)
                            await mockFileManager
                                .verify {
                                    $0.createFile(
                                        atPath: "/test/DisplayPictures/5465737448617368",
                                        contents: imageData,
                                        attributes: nil
                                    )
                                }
                                .wasCalled(exactly: 1)
                            await mockImageDataManager
                                .verify {
                                    await $0.load(
                                        .url(URL(fileURLWithPath: "/test/DisplayPictures/5465737448617368"))
                                    )
                                }
                                .wasCalled(exactly: 1, timeout: .milliseconds(100))
                            expect(mockStorage.read { db in try Profile.fetchOne(db) })
                                .to(equal(
                                    Profile(
                                        id: "1234",
                                        name: "test",
                                        displayPictureUrl: "http://oxen.io/100/",
                                        displayPictureEncryptionKey: encryptionKey,
                                        displayPictureLastUpdated: 1234567891
                                    )
                                ))
                        }
                    }
                    
                    // MARK: ------ updates the database values
                    it("updates the database values") {
                        expect(mockStorage.read { db in try Profile.fetchOne(db) })
                            .to(equal(
                                Profile(
                                    id: "1234",
                                    name: "test",
                                    displayPictureUrl: "http://oxen.io/100/",
                                    displayPictureEncryptionKey: encryptionKey,
                                    displayPictureLastUpdated: 1234567891
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
                            displayPictureUrl: "http://oxen.io/100/",
                            displayPictureEncryptionKey: encryptionKey,
                            shouldPoll: true,
                            groupIdentityPrivateKey: nil,
                            authData: Data([1, 2, 3]),
                            invited: false
                        )
                        mockStorage.write { db in
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
                        job = Job(
                            variant: .displayPictureDownload,
                            shouldBeUnique: true,
                            details: DisplayPictureDownloadJob.Details(
                                target: .group(
                                    id: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece",
                                    url: "http://oxen.io/100/",
                                    encryptionKey: encryptionKey
                                ),
                                timestamp: 1234567891
                            )
                        )
                    }
                    
                    // MARK: ------ that does not exist
                    context("that does not exist") {
                        beforeEach {
                            mockStorage.write { db in try ClosedGroup.deleteAll(db) }
                        }
                        
                        // MARK: -------- does not save the picture
                        it("does not save the picture") {
                            await mockCrypto
                                .verify { $0.generate(.decryptedDataDisplayPicture(data: .any, key: .any)) }
                                .wasNotCalled()
                            await mockFileManager
                                .verify { $0.createFile(atPath: .any, contents: .any, attributes: .any) }
                                .wasNotCalled()
                            await mockImageDataManager
                                .verify { await $0.load(.any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            expect(mockStorage.read { db in try ClosedGroup.fetchOne(db) }).to(beNil())
                        }
                    }
                    
                    // MARK: ------ that has a different encryption key and more recent update
                    context("that has a different encryption key and more recent update") {
                        beforeEach {
                            mockStorage.write { db in
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
                                .verify { $0.generate(.decryptedDataDisplayPicture(data: .any, key: .any)) }
                                .wasNotCalled()
                            await mockFileManager
                                .verify { $0.createFile(atPath: .any, contents: .any, attributes: .any) }
                                .wasNotCalled()
                            await mockImageDataManager
                                .verify { await $0.load(.any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            expect(mockStorage.read { db in try ClosedGroup.fetchOne(db) })
                                .toNot(equal(
                                    ClosedGroup(
                                        threadId: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece",
                                        name: "TestGroup",
                                        groupDescription: nil,
                                        formationTimestamp: 1234567890,
                                        displayPictureUrl: "http://oxen.io/100/",
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
                            mockStorage.write { db in
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
                                .verify { $0.generate(.decryptedDataDisplayPicture(data: .any, key: .any)) }
                                .wasNotCalled()
                            await mockFileManager
                                .verify { $0.createFile(atPath: .any, contents: .any, attributes: .any) }
                                .wasNotCalled()
                            await mockImageDataManager
                                .verify { await $0.load(.any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            expect(mockStorage.read { db in try ClosedGroup.fetchOne(db) })
                                .toNot(equal(
                                    ClosedGroup(
                                        threadId: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece",
                                        name: "TestGroup",
                                        groupDescription: nil,
                                        formationTimestamp: 1234567890,
                                        displayPictureUrl: "http://oxen.io/100/",
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
                        expect(mockStorage.read { db in try ClosedGroup.fetchOne(db) })
                            .to(equal(
                                ClosedGroup(
                                    threadId: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece",
                                    name: "TestGroup",
                                    groupDescription: nil,
                                    formationTimestamp: 1234567890,
                                    displayPictureUrl: "http://oxen.io/100/",
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
                            isActive: true,
                            name: "name",
                            imageId: "100",
                            userCount: 1,
                            infoUpdates: 1,
                            displayPictureOriginalUrl: nil
                        )
                        mockStorage.write { db in
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
                        job = Job(
                            variant: .displayPictureDownload,
                            shouldBeUnique: true,
                            details: DisplayPictureDownloadJob.Details(
                                target: .community(
                                    imageId: "100",
                                    roomToken: "testRoom",
                                    server: "testServer"
                                ),
                                timestamp: 1234567891
                            )
                        )
                        
                        // SOGS doesn't encrypt it's images so replace the encrypted mock response
                        try await mockNetwork
                            .when {
                                $0.send(
                                    endpoint: MockEndpoint.any,
                                    destination: .any,
                                    body: .any,
                                    category: .any,
                                    requestTimeout: .any,
                                    overallTimeout: .any
                                )
                            }
                            .thenReturn(MockNetwork.response(data: imageData))
                    }
                    
                    // MARK: ------ that does not exist
                    context("that does not exist") {
                        beforeEach {
                            mockStorage.write { db in try OpenGroup.deleteAll(db) }
                        }
                        
                        // MARK: -------- does not save the picture
                        it("does not save the picture") {
                            await mockFileManager
                                .verify { $0.createFile(atPath: .any, contents: .any, attributes: .any) }
                                .wasNotCalled()
                            await mockImageDataManager
                                .verify { await $0.load(.any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            expect(mockStorage.read { db in try OpenGroup.fetchOne(db) }).to(beNil())
                        }
                    }
                    
                    // MARK: ------ that has a different imageId
                    context("that has a different imageId") {
                        beforeEach {
                            mockStorage.write { db in
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
                                .wasNotCalled()
                            await mockImageDataManager
                                .verify { await $0.load(.any) }
                                .wasNotCalled(timeout: .milliseconds(100))
                            expect(mockStorage.read { db in try OpenGroup.fetchOne(db) })
                                .toNot(equal(
                                    OpenGroup(
                                        server: "testServer",
                                        roomToken: "testRoom",
                                        publicKey: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece",
                                        isActive: true,
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
                            mockStorage.write { db in
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
                                    $0.createFile(
                                        atPath: "/test/DisplayPictures/5465737448617368",
                                        contents: imageData,
                                        attributes: nil
                                    )
                                }
                                .wasCalled(exactly: 1)
                            await mockImageDataManager
                                .verify {
                                    await $0.load(
                                        .url(URL(fileURLWithPath: "/test/DisplayPictures/5465737448617368"))
                                    )
                                }
                                .wasCalled(exactly: 1, timeout: .milliseconds(100))
                            expect(mockStorage.read { db in try OpenGroup.fetchOne(db) })
                                .to(equal(
                                    OpenGroup(
                                        server: "testServer",
                                        roomToken: "testRoom",
                                        publicKey: "03cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece",
                                        isActive: true,
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
                                    isActive: true,
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
