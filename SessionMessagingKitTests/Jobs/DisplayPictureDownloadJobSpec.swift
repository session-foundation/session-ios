// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

import Quick
import Nimble

@testable import SessionSnodeKit
@testable import SessionMessagingKit
@testable import SessionUtilitiesKit

class DisplayPictureDownloadJobSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var job: Job!
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.forceSynchronous = true
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
        }
        @TestState(singleton: .storage, in: dependencies) var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            migrationTargets: [
                SNUtilitiesKit.self,
                SNMessagingKit.self
            ],
            using: dependencies,
            initialData: { db in
                try Identity(variant: .x25519PublicKey, data: Data.data(fromHex: TestConstants.publicKey)!).insert(db)
                try Identity(variant: .x25519PrivateKey, data: Data.data(fromHex: TestConstants.privateKey)!).insert(db)
                try Identity(variant: .ed25519PublicKey, data: Data.data(fromHex: TestConstants.edPublicKey)!).insert(db)
                try Identity(variant: .ed25519SecretKey, data: Data.data(fromHex: TestConstants.edSecretKey)!).insert(db)
            }
        )
        @TestState(singleton: .network, in: dependencies) var mockNetwork: MockNetwork! = MockNetwork(
            initialSetup: { mockNetwork in
                mockNetwork
                    .when { $0.send(.onionRequest(any(), to: any(), with: any())) }
                    .thenReturn(MockNetwork.response(data: Data([1, 2, 3])))
                
                mockNetwork
                    .when {
                        $0.send(
                            .onionRequest(any(), to: any(), with: any(), timeout: FileServerAPI.fileDownloadTimeout)
                        )
                    }
                    .thenReturn(MockNetwork.response(data: Data([1, 2, 3])))
            }
        )
        
        // MARK: - a DisplayPictureDownloadJob
        describe("a DisplayPictureDownloadJob") {
            // MARK: -- fails when not given any details
            it("fails when not given any details") {
                job = Job(variant: .displayPictureDownload)
                
                var error: Error? = nil
                var permanentFailure: Bool = false
                
                DisplayPictureDownloadJob.run(
                    job,
                    queue: .main,
                    success: { _, _, _ in },
                    failure: { _, runError, runPermanentFailure, _ in
                        error = runError
                        permanentFailure = runPermanentFailure
                    },
                    deferred: { _, _ in },
                    using: dependencies
                )
                
                expect(error).to(matchError(JobRunnerError.missingRequiredDetails))
                expect(permanentFailure).to(beTrue())
            }
            
            // MARK: -- when initialising details
            context("when initialising details") {
                // MARK: -- for a profile
                context("for a profile") {
                    // MARK: -- with a target
                    context("with a target") {
                        // MARK: ---- returns nil when given an empty url
                        it("returns nil when given an empty url") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .profile(id: "", url: "", encryptionKey: Data()),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: ---- returns nil when given a url which does not have a file id
                        it("returns nil when given a url which does not have a file id") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .profile(id: "", url: "http://oxen.io", encryptionKey: Data()),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: ---- returns nil when given a url which does not have a file id
                        it("returns nil when given a url which does not have a file id") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .profile(id: "", url: "http://oxen.io", encryptionKey: Data()),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: ---- returns nil when given encryption key data with the wrong length
                        it("returns nil when given encryption key data with the wrong length") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .profile(id: "", url: "http://oxen.io/1234/", encryptionKey: Data([1, 2, 3])),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: ---- returns a value when given valid data
                        it("returns a value when given valid data") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .profile(
                                        id: "",
                                        url: "http://oxen.io/1234/",
                                        encryptionKey: Data(repeating: 0, count: DisplayPictureManager.aes256KeyByteLength)
                                    ),
                                    timestamp: 0
                                )
                            ).toNot(beNil())
                        }
                    }
                    
                    // MARK: -- with an owner
                    context("with an owner") {
                        // MARK: ---- returns nil when given a null url
                        it("returns nil when given a null url") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    owner: .user(
                                        Profile(
                                            id: "1234",
                                            name: "test",
                                            profilePictureUrl: nil,
                                            profileEncryptionKey: Data(
                                                repeating: 0,
                                                count: DisplayPictureManager.aes256KeyByteLength
                                            )
                                        )
                                    )
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: ---- returns nil when given a null encryption key
                        it("returns nil when given a null encryption key") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    owner: .user(
                                        Profile(
                                            id: "1234",
                                            name: "test",
                                            profilePictureUrl: "http://oxen.io/1234/",
                                            profileEncryptionKey: nil
                                        )
                                    )
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: ---- returns a value when given valid data
                        it("returns a value when given valid data") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    owner: .user(
                                        Profile(
                                            id: "1234",
                                            name: "test",
                                            profilePictureUrl: "http://oxen.io/1234/",
                                            profileEncryptionKey: Data(
                                                repeating: 0,
                                                count: DisplayPictureManager.aes256KeyByteLength
                                            )
                                        )
                                    )
                                )
                            ).toNot(beNil())
                        }
                    }
                }
                
                // MARK: -- for a group
                context("for a group") {
                    // MARK: -- with a target
                    context("with a target") {
                        // MARK: ---- returns nil when given an empty url
                        it("returns nil when given an empty url") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .group(id: "", url: "", encryptionKey: Data()),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: ---- returns nil when given a url which does not have a file id
                        it("returns nil when given a url which does not have a file id") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .group(id: "", url: "http://oxen.io", encryptionKey: Data()),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: ---- returns nil when given a url which does not have a file id
                        it("returns nil when given a url which does not have a file id") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .group(id: "", url: "http://oxen.io", encryptionKey: Data()),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: ---- returns nil when given encryption key data with the wrong length
                        it("returns nil when given encryption key data with the wrong length") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .group(id: "", url: "http://oxen.io/1234/", encryptionKey: Data([1, 2, 3])),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: ---- returns a value when given valid data
                        it("returns a value when given valid data") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .group(
                                        id: "",
                                        url: "http://oxen.io/1234/",
                                        encryptionKey: Data(repeating: 0, count: DisplayPictureManager.aes256KeyByteLength)
                                    ),
                                    timestamp: 0
                                )
                            ).toNot(beNil())
                        }
                    }
                    
                    // MARK: -- with an owner
                    context("with an owner") {
                        // MARK: ---- returns nil when given a null url
                        it("returns nil when given a null url") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    owner: .group(
                                        ClosedGroup(
                                            threadId: "1234",
                                            name: "test",
                                            formationTimestamp: 0,
                                            displayPictureUrl: nil,
                                            displayPictureEncryptionKey: Data(
                                                repeating: 0,
                                                count: DisplayPictureManager.aes256KeyByteLength
                                            ),
                                            shouldPoll: nil,
                                            invited: nil
                                        )
                                    )
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: ---- returns nil when given a null encryption key
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
                        
                        // MARK: ---- returns a value when given valid data
                        it("returns a value when given valid data") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    owner: .group(
                                        ClosedGroup(
                                            threadId: "1234",
                                            name: "test",
                                            formationTimestamp: 0,
                                            displayPictureUrl: "http://oxen.io/1234/",
                                            displayPictureEncryptionKey: Data(
                                                repeating: 0,
                                                count: DisplayPictureManager.aes256KeyByteLength
                                            ),
                                            shouldPoll: nil,
                                            invited: nil
                                        )
                                    )
                                )
                            ).toNot(beNil())
                        }
                    }
                }
                
                // MARK: -- for a community
                context("for a community") {
                    // MARK: -- with a target
                    context("with a target") {
                        // MARK: ---- returns nil when given an empty imageId
                        it("returns nil when given an empty imageId") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .community(imageId: "", roomToken: "", server: ""),
                                    timestamp: 0
                                )
                            ).to(beNil())
                        }
                        
                        // MARK: ---- returns a value when given valid data
                        it("returns a value when given valid data") {
                            expect(
                                DisplayPictureDownloadJob.Details(
                                    target: .community(imageId: "12", roomToken: "", server: ""),
                                    timestamp: 0
                                )
                            ).toNot(beNil())
                        }
                    }
                    
                    // MARK: -- with an owner
                    context("with an owner") {
                        // MARK: ---- returns nil when given an empty imageId
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
                        
                        // MARK: ---- returns a value when given valid data
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
                            url: "http://oxen.io/1234/",
                            encryptionKey: Data(repeating: 0, count: DisplayPictureManager.aes256KeyByteLength)
                        ),
                        timestamp: 0
                    )
                )
                let expectedRequest: URLRequest = try FileServerAPI
                    .preparedDownload(
                        fileId: "1234",
                        useOldServer: false,
                        using: dependencies
                    )
                    .request
                
                DisplayPictureDownloadJob.run(
                    job,
                    queue: .main,
                    success: { _, _, _ in },
                    failure: { _, _, _, _ in },
                    deferred: { _, _ in },
                    using: dependencies
                )
                
                expect(mockNetwork)
                    .to(call(.exactly(times: 1), matchingParameters: .all) { network in
                        network.send(
                            .onionRequest(
                                expectedRequest,
                                to: FileServerAPI.server,
                                with: FileServerAPI.serverPublicKey,
                                timeout: FileServerAPI.fileDownloadTimeout
                            )
                        )
                    })
            }
            
            // MARK: -- generates a SOGS download request correctly
            it("generates a SOGS download request correctly") {
                mockStorage.write(using: dependencies) { db in
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
                let expectedRequest: URLRequest = mockStorage
                    .read(using: dependencies) { db in
                        try OpenGroupAPI.preparedDownloadFile(
                            db,
                            fileId: "12",
                            from: "testRoom",
                            on: "testserver",
                            using: dependencies
                        )
                    }!
                    .request
                
                DisplayPictureDownloadJob.run(
                    job,
                    queue: .main,
                    success: { _, _, _ in },
                    failure: { _, _, _, _ in },
                    deferred: { _, _ in },
                    using: dependencies
                )
                
                expect(mockNetwork)
                    .to(call(.exactly(times: 1), matchingParameters: .all) { network in
                        network.send(
                            .onionRequest(
                                expectedRequest,
                                to: "testserver",
                                with: TestConstants.serverPublicKey,
                                timeout: FileServerAPI.fileDownloadTimeout
                            )
                        )
                    })
            }
        }
    }
}
