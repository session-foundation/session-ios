// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import TestUtilities

import Quick
import Nimble

@testable import SessionMessagingKit
@testable import SessionUtilitiesKit

class MessageSendJobSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var job: Job!
        @TestState var interaction: Interaction!
        @TestState var attachment: Attachment! = Attachment(
            id: "200",
            variant: .standard,
            state: .failedDownload,
            contentType: "text/plain",
            byteCount: 200
        )
        @TestState var interactionAttachment: InteractionAttachment!
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
        }
        @TestState var mockLibSessionCache: MockLibSessionCache! = .create(using: dependencies)
        @TestState var mockStorage: Storage! = SynchronousStorage(
            customWriter: try! DatabaseQueue(),
            using: dependencies
        )
        @TestState var mockJobRunner: MockJobRunner! = .create(using: dependencies)
        
        beforeEach {
            try await mockLibSessionCache.defaultInitialSetup()
            dependencies.set(cache: .libSession, to: mockLibSessionCache)
            
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            try await mockStorage.writeAsync { db in
                try SessionThread.upsert(
                    db,
                    id: "Test1",
                    variant: .contact,
                    values: SessionThread.TargetValues(
                        creationDateTimestamp: .setTo(1234567890),
                        // False is the default and will mean we don't need libSession loaded
                        shouldBeVisible: .setTo(false)
                    ),
                    using: dependencies
                )
            }
            dependencies.set(singleton: .storage, to: mockStorage)
            
            try await mockJobRunner
                .when {
                    $0.jobInfoFor(
                        jobs: nil,
                        state: .anyState,
                        variant: .attachmentUpload
                    )
                }
                .thenReturn([:])
            try await mockJobRunner
                .when { $0.insert(.any, job: .any, before: .any) }
                .then { args in
                    let db: ObservingDatabase = args[0] as! ObservingDatabase
                    var job: Job = args[1] as! Job
                    job.id = 1000
                    
                    try! job.insert(db)
                }
                .thenReturn((1000, Job(variant: .messageSend)))
            dependencies.set(singleton: .jobRunner, to: mockJobRunner)
        }
        
        // MARK: - a MessageSendJob
        describe("a MessageSendJob") {
            // MARK: -- fails when not given any details
            it("fails when not given any details") {
                job = Job(variant: .messageSend)
                
                var error: Error? = nil
                var permanentFailure: Bool = false
                
                MessageSendJob.run(
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
            
            // MARK: -- fails when not give a thread id
            it("fails when not give a thread id") {
                job = Job(
                    variant: .messageSend,
                    threadId: nil,
                    details: MessageSendJob.Details(
                        destination: .contact(publicKey: "Test"),
                        message: VisibleMessage(
                            text: "Test"
                        )
                    )
                )
                
                var error: Error? = nil
                var permanentFailure: Bool = false
                
                MessageSendJob.run(
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
            
            // MARK: -- fails when given incorrect details
            it("fails when given incorrect details") {
                job = Job(
                    variant: .messageSend,
                    threadId: "Test",
                    details: MessageReceiveJob.Details(
                        messages: [MessageReceiveJob.Details.MessageInfo]()
                    )
                )
                
                var error: Error? = nil
                var permanentFailure: Bool = false
                
                MessageSendJob.run(
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
            
            // MARK: -- of VisibleMessage
            context("of VisibleMessage") {
                beforeEach {
                    interaction = Interaction(
                        id: 100,
                        serverHash: nil,
                        messageUuid: nil,
                        threadId: "Test1",
                        authorId: "Test",
                        variant: .standardOutgoing,
                        body: "Test",
                        timestampMs: 1234567890,
                        receivedAtTimestampMs: 1234567900,
                        wasRead: false,
                        hasMention: false,
                        expiresInSeconds: nil,
                        expiresStartedAtMs: nil,
                        linkPreviewUrl: nil,
                        openGroupServerMessageId: nil,
                        openGroupWhisper: false,
                        openGroupWhisperMods: false,
                        openGroupWhisperTo: nil,
                        state: .sending,
                        recipientReadTimestampMs: nil,
                        mostRecentFailureText: nil,
                        isProMessage: false
                    )
                    job = Job(
                        variant: .messageSend,
                        threadId: "Test1",
                        interactionId: interaction.id!,
                        details: MessageSendJob.Details(
                            destination: .contact(publicKey: "Test"),
                            message: VisibleMessage(
                                text: "Test"
                            )
                        )
                    )
                    
                    mockStorage.write { db in
                        try interaction.insert(db)
                        job.id = 54321
                        try job.insert(db)
                    }
                }
                
                // MARK: ---- fails when there is no job id
                it("fails when there is no job id") {
                    job = Job(
                        variant: .messageSend,
                        threadId: "Test1",
                        interactionId: interaction.id!,
                        details: MessageSendJob.Details(
                            destination: .contact(publicKey: "Test"),
                            message: VisibleMessage(
                                text: "Test"
                            )
                        )
                    )
                    
                    var error: Error? = nil
                    var permanentFailure: Bool = false
                    
                    MessageSendJob.run(
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
                
                // MARK: ---- fails when there is no interaction id
                it("fails when there is no interaction id") {
                    job = Job(
                        variant: .messageSend,
                        threadId: "Test1",
                        details: MessageSendJob.Details(
                            destination: .contact(publicKey: "Test"),
                            message: VisibleMessage(
                                text: "Test"
                            )
                        )
                    )
                    
                    var error: Error? = nil
                    var permanentFailure: Bool = false
                    
                    MessageSendJob.run(
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
                
                // MARK: ---- fails when there is no interaction for the provided interaction id
                it("fails when there is no interaction for the provided interaction id") {
                    job = Job(
                        variant: .messageSend,
                        threadId: "Test1",
                        interactionId: 12345,
                        details: MessageSendJob.Details(
                            destination: .contact(publicKey: "Test"),
                            message: VisibleMessage(
                                text: "Test"
                            )
                        )
                    )
                    mockStorage.write { db in
                        job.id = 54321
                        try job.insert(db)
                    }
                    
                    var error: Error? = nil
                    var permanentFailure: Bool = false
                    
                    MessageSendJob.run(
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
                    
                    expect(error).to(matchError(StorageError.objectNotFound))
                    expect(permanentFailure).to(beTrue())
                }
                
                // MARK: ---- with an attachment
                context("with an attachment") {
                    beforeEach {
                        interactionAttachment = InteractionAttachment(
                            albumIndex: 0,
                            interactionId: interaction.id!,
                            attachmentId: attachment.id
                        )
                        
                        mockStorage.write { db in
                            try attachment.insert(db)
                            try interactionAttachment.insert(db)
                        }
                    }
                    
                    // MARK: ------ it fails when trying to send with an attachment which previously failed to download
                    it("it fails when trying to send with an attachment which previously failed to download") {
                        mockStorage.write { db in
                            try attachment.with(state: .failedDownload, using: dependencies).upsert(db)
                        }
                        
                        var error: Error? = nil
                        var permanentFailure: Bool = false
                        
                        MessageSendJob.run(
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
                        
                        expect(error).to(matchError(AttachmentError.notUploaded))
                        expect(permanentFailure).to(beTrue())
                    }
                    
                    // MARK: ------ with a pending upload
                    context("with a pending upload") {
                        beforeEach {
                            mockStorage.write { db in
                                try attachment.with(state: .uploading, using: dependencies).upsert(db)
                            }
                        }
                        
                        // MARK: -------- it defers when trying to send with an attachment which is still pending upload
                        it("it defers when trying to send with an attachment which is still pending upload") {
                            var didDefer: Bool = false
                            
                            mockStorage.write { db in
                                try attachment.with(state: .uploading, using: dependencies).upsert(db)
                            }
                            
                            MessageSendJob.run(
                                job,
                                scheduler: DispatchQueue.main,
                                success: { _, _ in },
                                failure: { _, _, _ in },
                                deferred: { _ in didDefer = true },
                                using: dependencies
                            )
                            
                            expect(didDefer).to(beTrue())
                        }
                        
                        // MARK: -------- it defers when trying to send with an uploaded attachment that has an invalid downloadUrl
                        it("it defers when trying to send with an uploaded attachment that has an invalid downloadUrl") {
                            var didDefer: Bool = false
                            
                            mockStorage.write { db in
                                try attachment
                                    .with(
                                        state: .uploaded,
                                        downloadUrl: nil,
                                        using: dependencies
                                    )
                                    .upsert(db)
                            }
                            
                            MessageSendJob.run(
                                job,
                                scheduler: DispatchQueue.main,
                                success: { _, _ in },
                                failure: { _, _, _ in },
                                deferred: { _ in didDefer = true },
                                using: dependencies
                            )
                            
                            expect(didDefer).to(beTrue())
                        }
                        
                        // MARK: -------- inserts an attachment upload job before the message send job
                        it("inserts an attachment upload job before the message send job") {
                            try await mockJobRunner
                                .when {
                                    $0.jobInfoFor(
                                        jobs: nil,
                                        state: .running,
                                        variant: .attachmentUpload
                                    )
                                }
                                .thenReturn([:])
                            
                            MessageSendJob.run(
                                job,
                                scheduler: DispatchQueue.main,
                                success: { _, _ in },
                                failure: { _, _, _ in },
                                deferred: { _ in },
                                using: dependencies
                            )
                            
                            await mockJobRunner
                                .verify {
                                    $0.insert(
                                        .any,
                                        job: Job(
                                            variant: .attachmentUpload,
                                            behaviour: .runOnce,
                                            shouldBlock: false,
                                            shouldSkipLaunchBecomeActive: false,
                                            threadId: "Test1",
                                            interactionId: 100,
                                            details: AttachmentUploadJob.Details(
                                                messageSendJobId: 54321,
                                                attachmentId: "200"
                                            )
                                        ),
                                        before: job
                                    )
                                }
                                .wasCalled(exactly: 1, timeout: .milliseconds(100))
                        }
                        
                        // MARK: -------- creates a dependency between the new job and the existing one
                        it("creates a dependency between the new job and the existing one") {
                            MessageSendJob.run(
                                job,
                                scheduler: DispatchQueue.main,
                                success: { _, _ in },
                                failure: { _, _, _ in },
                                deferred: { _ in },
                                using: dependencies
                            )
                            
                            await expect(mockStorage.read { db in try JobDependencies.fetchOne(db) })
                                .toEventually(equal(JobDependencies(jobId: 54321, dependantId: 1000)))
                        }
                    }
                }
            }
        }
    }
}
