// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

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
            byteCount: 200,
            downloadUrl: "http://localhost"
        )
        @TestState var interactionAttachment: InteractionAttachment!
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
        }
        @TestState var mockLibSessionCache: MockLibSessionCache! = .create(using: dependencies)
        @TestState var mockStorage: Storage! = try! Storage.createForTesting(using: dependencies)
        @TestState var mockJobRunner: MockJobRunner! = .create(using: dependencies)
        
        beforeEach {
            dependencies.set(cache: .libSession, to: mockLibSessionCache)
            try await mockLibSessionCache.defaultInitialSetup()
            
            dependencies.set(singleton: .storage, to: mockStorage)
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            try await mockStorage.write { db in
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
            
            dependencies.set(singleton: .jobRunner, to: mockJobRunner)
            try await mockJobRunner
                .when { $0.add(.any, job: .any, initialDependencies: .any) }
                .thenReturn(.mock)
            try await mockJobRunner
                .when { await $0.jobsMatching(filters: .any) }
                .thenReturn([:])
            try await mockJobRunner
                .when { try $0.addJobDependency(.any, .any) }
                .thenReturn(())
        }
        
        // MARK: - a MessageSendJob
        describe("a MessageSendJob") {
            // MARK: -- fails when not given any details
            it("fails when not given any details") {
                await expect {
                    try await MessageSendJob.run(
                        Job(variant: .messageSend),
                        using: dependencies
                    )
                }.to(throwError(JobRunnerError.missingRequiredDetails))
            }
            
            // MARK: -- fails when not give a thread id
            it("fails when not give a thread id") {
                await expect {
                    try await MessageSendJob.run(
                        Job(
                            variant: .messageSend,
                            threadId: nil,
                            details: MessageSendJob.Details(
                                destination: .contact(publicKey: "Test"),
                                message: VisibleMessage(
                                    text: "Test"
                                ),
                                ignorePermanentFailure: false
                            )
                        )!,
                        using: dependencies
                    )
                }.to(throwError(JobRunnerError.missingRequiredDetails))
            }
            
            // MARK: -- fails when given incorrect details
            it("fails when given incorrect details") {
                await expect {
                    try await MessageSendJob.run(
                        Job(
                            variant: .messageSend,
                            threadId: "Test",
                            details: MessageReceiveJob.Details(
                                messages: [MessageReceiveJob.Details.MessageInfo]()
                            )
                        )!,
                        using: dependencies
                    )
                }.to(throwError(JobRunnerError.missingRequiredDetails))
            }
        }
        
        // MARK: - a MessageSendJob
        describe("a MessageSendJob") {
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
                        proMessageFeatures: .none,
                        proProfileFeatures: .none
                    )
                    job = Job(
                        variant: .messageSend,
                        threadId: "Test1",
                        interactionId: interaction.id!,
                        details: MessageSendJob.Details(
                            destination: .contact(publicKey: "Test"),
                            message: VisibleMessage(
                                text: "Test"
                            ),
                            ignorePermanentFailure: false
                        )
                    )
                    
                    try await mockStorage.write { db in
                        try interaction.insert(db)
                        job.id = 54321
                        try job.insert(db)
                    }
                }
                
                // MARK: ---- fails when there is no job id
                it("fails when there is no job id") {
                    await expect {
                        try await MessageSendJob.run(
                            Job(
                                variant: .messageSend,
                                threadId: "Test1",
                                interactionId: interaction.id!,
                                details: MessageSendJob.Details(
                                    destination: .contact(publicKey: "Test"),
                                    message: VisibleMessage(
                                        text: "Test"
                                    ),
                                    ignorePermanentFailure: false
                                )
                            )!,
                            using: dependencies
                        )
                    }.to(throwError(JobRunnerError.missingRequiredDetails))
                }
                
                // MARK: ---- fails when there is no interaction id
                it("fails when there is no interaction id") {
                    await expect {
                        try await MessageSendJob.run(
                            Job(
                                variant: .messageSend,
                                threadId: "Test1",
                                details: MessageSendJob.Details(
                                    destination: .contact(publicKey: "Test"),
                                    message: VisibleMessage(
                                        text: "Test"
                                    ),
                                    ignorePermanentFailure: false
                                )
                            )!,
                            using: dependencies
                        )
                    }.to(throwError(JobRunnerError.missingRequiredDetails))
                }
                
                // MARK: ---- fails when there is no interaction for the provided interaction id
                it("fails when there is no interaction for the provided interaction id") {
                    await expect {
                        try await MessageSendJob.run(
                            Job(
                                variant: .messageSend,
                                threadId: "Test1",
                                interactionId: 12345,
                                details: MessageSendJob.Details(
                                    destination: .contact(publicKey: "Test"),
                                    message: VisibleMessage(
                                        text: "Test"
                                    ),
                                    ignorePermanentFailure: false
                                )
                            )!,
                            using: dependencies
                        )
                    }.to(throwError(JobRunnerError.missingRequiredDetails))
                }
            }
        }
        
        // MARK: - a MessageSendJob
        describe("a MessageSendJob") {
            // MARK: -- of VisibleMessage with an attachment
            context("of VisibleMessage with an attachment") {
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
                        proMessageFeatures: .none,
                        proProfileFeatures: .none
                    )
                    job = Job(
                        variant: .messageSend,
                        threadId: "Test1",
                        interactionId: interaction.id!,
                        details: MessageSendJob.Details(
                            destination: .contact(publicKey: "Test"),
                            message: VisibleMessage(
                                text: "Test"
                            ),
                            ignorePermanentFailure: false
                        )
                    )
                    interactionAttachment = InteractionAttachment(
                        albumIndex: 0,
                        interactionId: interaction.id!,
                        attachmentId: attachment.id
                    )
                    
                    try await mockStorage.write { db in
                        try interaction.insert(db)
                        job.id = 54321
                        try job.insert(db)
                        
                        try attachment.insert(db)
                        try interactionAttachment.insert(db)
                    }
                }
                
                // MARK: ------ it fails when trying to send with an attachment which previously failed to download
                it("it fails when trying to send with an attachment which previously failed to download") {
                    try await mockStorage.write { db in
                        try attachment.with(state: .failedDownload, using: dependencies).upsert(db)
                    }
                    
                    await expect {
                        try await MessageSendJob.run(job, using: dependencies)
                    }.to(throwError(JobRunnerError.permanentFailure(AttachmentError.notUploaded)))
                }
                
                // MARK: ------ with a pending upload
                context("with a pending upload") {
                    beforeEach {
                        try await mockStorage.write { db in
                            try attachment.with(state: .uploading, using: dependencies).upsert(db)
                        }
                    }
                    
                    // MARK: -------- it defers when trying to send with an attachment which is still pending upload
                    it("it defers when trying to send with an attachment which is still pending upload") {
                        await expect {
                            try await MessageSendJob.run(job, using: dependencies)
                        }.to(equal(.deferred(nextRunTimestamp: nil)))
                    }
                    
                    // MARK: -------- it defers when trying to send with an uploaded attachment that has an invalid downloadUrl
                    it("it defers when trying to send with an uploaded attachment that has an invalid downloadUrl") {
                        try await mockStorage.write { db in
                            try Attachment(
                                id: attachment.id,
                                serverId: attachment.serverId,
                                variant: attachment.variant,
                                state: .uploaded,
                                contentType: attachment.contentType,
                                byteCount: attachment.byteCount,
                                creationTimestamp: attachment.creationTimestamp,
                                sourceFilename: attachment.sourceFilename,
                                downloadUrl: nil,
                                width: attachment.width,
                                height: attachment.height,
                                duration: attachment.duration,
                                isVisualMedia: attachment.isVisualMedia,
                                isValid: attachment.isValid,
                                encryptionKey: attachment.encryptionKey,
                                digest: attachment.digest
                            ).upsert(db)
                        }
                        
                        await expect {
                            try await MessageSendJob.run(job, using: dependencies)
                        }.to(equal(.deferred(nextRunTimestamp: nil)))
                    }
                    
                    // MARK: -------- adds the attachment upload job as a dependency
                    it("adds the attachment upload job as a dependency") {
                        try await mockJobRunner
                            .when { $0.add(.any, job: .any, initialDependencies: .any) }
                            .thenReturn(
                                Job(
                                    id: 67890,
                                    failureCount: 0,
                                    variant: .attachmentUpload,
                                    threadId: nil,
                                    interactionId: nil,
                                    uniqueHashValue: nil,
                                    details: nil,
                                    transientData: nil
                                )
                            )
                        
                        _ = try? await MessageSendJob.run(job, using: dependencies)
                        
                        await mockJobRunner
                            .verify {
                                $0.add(
                                    .any,
                                    job: Job(
                                        failureCount: 0,
                                        variant: .attachmentUpload,
                                        threadId: "Test1",
                                        interactionId: 100,
                                        details: AttachmentUploadJob.Details(
                                            messageSendJobId: 54321,
                                            attachmentId: "200"
                                        ),
                                        transientData: nil
                                    ),
                                    initialDependencies: []
                                )
                            }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                        await mockJobRunner
                            .verify {
                                try $0.addJobDependency(
                                    .any,
                                    .job(jobId: 54321, otherJobId: 67890)
                                )
                            }
                            .wasCalled(exactly: 1, timeout: .milliseconds(100))
                    }
                }
            }
        }
    }
}
