// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

import Quick
import Nimble

@testable import SessionMessagingKit
@testable import SessionUtilitiesKit

class MessageSendJobSpec: QuickSpec {
    // MARK: - Spec

    override func spec() {
        var job: Job!
        var interaction: Interaction!
        var attachment1: Attachment!
        var interactionAttachment1: InteractionAttachment!
        var mockStorage: Storage!
        var mockJobRunner: MockJobRunner!
        var dependencies: Dependencies!
        
        // MARK: - JobRunner
        
        describe("a MessageSendJob") {
            beforeEach {
                mockStorage = Storage(
                    customWriter: try! DatabaseQueue(),
                    customMigrationTargets: [
                        SNUtilitiesKit.self,
                        SNMessagingKit.self
                    ]
                )
                mockJobRunner = MockJobRunner()
                dependencies = Dependencies(
                    storage: mockStorage,
                    jobRunner: mockJobRunner,
                    date: Date(timeIntervalSince1970: 1234567890)
                )
                attachment1 = Attachment(
                    id: "200",
                    variant: .standard,
                    state: .failedDownload,
                    contentType: "text/plain",
                    byteCount: 200
                )
                
                mockStorage.write { db in
                    try SessionThread.fetchOrCreate(db, id: "Test1", variant: .contact, shouldBeVisible: true)
                }
                
                mockJobRunner
                    .when {
                        $0.jobInfoFor(
                            jobs: nil,
                            state: .running,
                            variant: .attachmentUpload
                        )
                    }
                    .thenReturn([:])
                mockJobRunner
                    .when { $0.insert(any(), job: any(), before: any(), dependencies: dependencies) }
                    .then { args in
                        let db: Database = args[0] as! Database
                        var job: Job = args[1] as! Job
                        job.id = 1000
                        
                        try! job.insert(db)
                    }
                    .thenReturn((1000, Job(variant: .messageSend)))
            }
            
            afterEach {
                job = nil
                mockStorage = nil
                dependencies = nil
            }
            
            it("fails when not given any details") {
                job = Job(variant: .messageSend)
                
                var error: Error? = nil
                var permanentFailure: Bool = false
                
                MessageSendJob.run(
                    job,
                    queue: .main,
                    success: { _, _, _ in },
                    failure: { _, runError, runPermanentFailure, _ in
                        error = runError
                        permanentFailure = runPermanentFailure
                    },
                    deferred: { _, _ in },
                    dependencies: dependencies
                )
                
                expect(error).to(matchError(JobRunnerError.missingRequiredDetails))
                expect(permanentFailure).to(beTrue())
            }
            
            it("fails when not given incorrect details") {
                job = Job(
                    variant: .messageSend,
                    details: MessageReceiveJob.Details(messages: [], calledFromBackgroundPoller: false)
                )
                
                var error: Error? = nil
                var permanentFailure: Bool = false
                
                MessageSendJob.run(
                    job,
                    queue: .main,
                    success: { _, _, _ in },
                    failure: { _, runError, runPermanentFailure, _ in
                        error = runError
                        permanentFailure = runPermanentFailure
                    },
                    deferred: { _, _ in },
                    dependencies: dependencies
                )
                
                expect(error).to(matchError(JobRunnerError.missingRequiredDetails))
                expect(permanentFailure).to(beTrue())
            }
            
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
                        openGroupWhisperMods: false,
                        openGroupWhisperTo: nil
                    )
                    job = Job(
                        variant: .messageSend,
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
                        try job.insert(db)
                    }
                }
                
                it("fails when there is no job id") {
                    job = Job(
                        variant: .messageSend,
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
                        queue: .main,
                        success: { _, _, _ in },
                        failure: { _, runError, runPermanentFailure, _ in
                            error = runError
                            permanentFailure = runPermanentFailure
                        },
                        deferred: { _, _ in },
                        dependencies: dependencies
                    )
                    
                    expect(error).to(matchError(JobRunnerError.missingRequiredDetails))
                    expect(permanentFailure).to(beTrue())
                }
                
                it("fails when there is no interaction id") {
                    job = Job(
                        variant: .messageSend,
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
                        queue: .main,
                        success: { _, _, _ in },
                        failure: { _, runError, runPermanentFailure, _ in
                            error = runError
                            permanentFailure = runPermanentFailure
                        },
                        deferred: { _, _ in },
                        dependencies: dependencies
                    )
                    
                    expect(error).to(matchError(JobRunnerError.missingRequiredDetails))
                    expect(permanentFailure).to(beTrue())
                }
                
                it("fails when there is no interaction for the provided interaction id") {
                    job = Job(
                        variant: .messageSend,
                        interactionId: 12345,
                        details: MessageSendJob.Details(
                            destination: .contact(publicKey: "Test"),
                            message: VisibleMessage(
                                text: "Test"
                            )
                        )
                    )
                    mockStorage.write { db in try job.insert(db) }
                    
                    var error: Error? = nil
                    var permanentFailure: Bool = false
                    
                    MessageSendJob.run(
                        job,
                        queue: .main,
                        success: { _, _, _ in },
                        failure: { _, runError, runPermanentFailure, _ in
                            error = runError
                            permanentFailure = runPermanentFailure
                        },
                        deferred: { _, _ in },
                        dependencies: dependencies
                    )
                    
                    expect(error).to(matchError(StorageError.objectNotFound))
                    expect(permanentFailure).to(beTrue())
                }
                context("with an attachment") {
                    beforeEach {
                        interactionAttachment1 = InteractionAttachment(
                            albumIndex: 0,
                            interactionId: interaction.id!,
                            attachmentId: attachment1.id
                        )
                        
                        mockStorage.write { db in
                            try attachment1.insert(db)
                            try interactionAttachment1.insert(db)
                        }
                    }
                    
                    it("it fails when trying to send with an attachment which previously failed to download") {
                        mockStorage.write { db in
                            try attachment1.with(state: .failedDownload).save(db)
                        }
                        
                        var error: Error? = nil
                        var permanentFailure: Bool = false
                        
                        MessageSendJob.run(
                            job,
                            queue: .main,
                            success: { _, _, _ in },
                            failure: { _, runError, runPermanentFailure, _ in
                                error = runError
                                permanentFailure = runPermanentFailure
                            },
                            deferred: { _, _ in },
                            dependencies: dependencies
                        )
                        
                        expect(error).to(matchError(AttachmentError.notUploaded))
                        expect(permanentFailure).to(beTrue())
                    }
                    
                    it("it fails when trying to send with an attachment that has an invalid downloadUrl") {
                        mockStorage.write { db in
                            try attachment1
                                .with(
                                    state: .uploaded,
                                    downloadUrl: nil
                                )
                                .save(db)
                        }
                        
                        var error: Error? = nil
                        var permanentFailure: Bool = false
                        
                        MessageSendJob.run(
                            job,
                            queue: .main,
                            success: { _, _, _ in },
                            failure: { _, runError, runPermanentFailure, _ in
                                error = runError
                                permanentFailure = runPermanentFailure
                            },
                            deferred: { _, _ in },
                            dependencies: dependencies
                        )
                        
                        expect(error).to(matchError(AttachmentError.notUploaded))
                        expect(permanentFailure).to(beTrue())
                    }
                    
                    context("with a pending upload") {
                        beforeEach {
                            mockStorage.write { db in
                                try attachment1.with(state: .uploading).save(db)
                            }
                        }
                        
                        it("it defers when trying to send with an attachment which is still pending upload") {
                            var didDefer: Bool = false
                            
                            mockStorage.write { db in
                                try attachment1.with(state: .uploading).save(db)
                            }
                            
                            MessageSendJob.run(
                                job,
                                queue: .main,
                                success: { _, _, _ in },
                                failure: { _, _, _, _ in },
                                deferred: { _, _ in didDefer = true },
                                dependencies: dependencies
                            )
                            
                            expect(didDefer).to(beTrue())
                        }
                        
                        it("inserts an attachment upload job before the message send job") {
                            mockJobRunner
                                .when {
                                    $0.jobInfoFor(
                                        jobs: nil,
                                        state: .running,
                                        variant: .attachmentUpload
                                    )
                                }
                                .thenReturn([
                                    2: JobRunner.JobInfo(
                                        variant: .attachmentUpload,
                                        threadId: nil,
                                        interactionId: 100,
                                        detailsData: try! JSONEncoder().encode(AttachmentUploadJob.Details(
                                            messageSendJobId: 1,
                                            attachmentId: "200"
                                        ))
                                    )
                                ])
                            
                            MessageSendJob.run(
                                job,
                                queue: .main,
                                success: { _, _, _ in },
                                failure: { _, _, _, _ in },
                                deferred: { _, _ in },
                                dependencies: dependencies
                            )
                            
                            expect(mockJobRunner)
                                .to(call(.exactly(times: 1), matchingParameters: true) {
                                    $0.insert(
                                        any(),
                                        job: Job(
                                            variant: .attachmentUpload,
                                            behaviour: .runOnce,
                                            shouldBlock: false,
                                            shouldSkipLaunchBecomeActive: false,
                                            interactionId: 100,
                                            details: AttachmentUploadJob.Details(
                                                messageSendJobId: 1,
                                                attachmentId: "200"
                                            )
                                        ),
                                        before: job,
                                        dependencies: dependencies
                                    )
                                })
                        }
                        
                        it("creates a dependency between the new job and the existing one") {
                            MessageSendJob.run(
                                job,
                                queue: .main,
                                success: { _, _, _ in },
                                failure: { _, _, _, _ in },
                                deferred: { _, _ in },
                                dependencies: dependencies
                            )
                            
                            expect(mockStorage.read { db in try JobDependencies.fetchOne(db) })
                                .to(equal(JobDependencies(jobId: 9, dependantId: 1000)))
                        }
                    }
                }
            }
        }
    }
}
