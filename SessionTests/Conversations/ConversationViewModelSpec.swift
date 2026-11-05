// Copyright © 2026 Session Technology Foundation. All rights reserved.

import UIKit
import GRDB
import Quick
import Nimble
import SessionUIKit
import SessionNetworkingKit
import SessionUtilitiesKit
import TestUtilities

@testable import SessionMessagingKit
@testable import Session

class ConversationViewModelSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var userPubkey: String! = "05\(TestConstants.publicKey)"
        @TestState var contactPubkey: String! = "05\(TestConstants.publicKey.replacingOccurrences(of: "8", with: "7"))"
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies[singleton: .scheduler] = .immediate
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
        }
        @TestState var mockStorage: Storage! = try! Storage.createForTesting(using: dependencies)
        @TestState var mockGeneralCache: MockGeneralCache! = .create(using: dependencies)
        @TestState var mockJobRunner: MockJobRunner! = .create(using: dependencies)
        @TestState var mockLibSessionCache: MockLibSessionCache! = .create(using: dependencies)
        @TestState var mockNetwork: MockNetwork! = .create(using: dependencies)
        @TestState var viewModel: ConversationViewModel!
        @TestState var interactionIds: [Attachment.State: Int64]! = [:]
        
        func downloadJob(for state: Attachment.State) -> Job? {
            return Job(
                variant: .attachmentDownload,
                threadId: contactPubkey,
                interactionId: interactionIds[state],
                details: AttachmentDownloadJob.Details(attachmentId: "attachment-\(state)")
            )
        }
        
        beforeEach {
            dependencies.set(cache: .general, to: mockGeneralCache)
            try await mockGeneralCache.defaultInitialSetup()
            
            dependencies.set(cache: .libSession, to: mockLibSessionCache)
            try await mockLibSessionCache.defaultInitialSetup()
            
            dependencies.set(singleton: .network, to: mockNetwork)
            try await mockNetwork.defaultInitialSetup(using: dependencies)
            
            dependencies.set(singleton: .jobRunner, to: mockJobRunner)
            try await mockJobRunner
                .when { $0.add(.any, job: .any, initialDependencies: .any) }
                .thenReturn(.mock)
            
            dependencies.set(singleton: .storage, to: mockStorage)
            try await mockStorage.perform(migrations: SNMessagingKit.migrations)
            try await mockStorage.write { db in
                try Identity(
                    variant: .x25519PublicKey,
                    data: Data(hex: TestConstants.publicKey)
                ).insert(db)
                try SessionThread(
                    id: contactPubkey,
                    variant: .contact,
                    creationDateTimestamp: 0
                ).insert(db)
                try Contact(
                    id: contactPubkey,
                    isTrusted: false,
                    isApproved: true,
                    didApproveMe: true,
                    currentUserSessionId: SessionId(.standard, hex: userPubkey)
                ).insert(db)
                
                let states: [Attachment.State] = [.pendingDownload, .failedDownload, .invalid, .downloaded]
                
                for (index, state) in states.enumerated() {
                    let interaction: Interaction = try Interaction(
                        threadId: contactPubkey,
                        threadVariant: .contact,
                        authorId: contactPubkey,
                        variant: .standardIncoming,
                        timestampMs: Int64(1234567890000 + index),
                        using: dependencies
                    ).inserted(db)
                    interactionIds[state] = interaction.id
                    
                    try Attachment(
                        id: "attachment-\(state)",
                        variant: .voiceMessage,
                        state: state,
                        contentType: "audio/mpeg",
                        byteCount: 1234,
                        downloadUrl: "http://filev2.getsession.org/file/\(index)"
                    ).insert(db)
                    try InteractionAttachment(
                        albumIndex: 0,
                        interactionId: interaction.id!,
                        attachmentId: "attachment-\(state)"
                    ).insert(db)
                }
            }
            
            viewModel = await ConversationViewModel(
                threadInfo: ConversationInfoViewModel(
                    thread: SessionThread(
                        id: contactPubkey,
                        variant: .contact,
                        creationDateTimestamp: 0
                    ),
                    dataCache: ConversationDataCache(
                        userSessionId: SessionId(.standard, hex: userPubkey),
                        context: ConversationDataCache.Context(
                            source: .messageList(threadId: contactPubkey),
                            requireFullRefresh: false,
                            requireAuthMethodFetch: false,
                            requiresMessageRequestCountUpdate: false,
                            requiresPinnedConversationCountUpdate: false,
                            requiresInitialUnreadInteractionInfo: false,
                            requireRecentReactionEmojiUpdate: false
                        )
                    ),
                    using: dependencies
                ),
                currentUserMentionImage: UIImage(),
                using: dependencies
            )
        }
        
        // MARK: - a ConversationViewModel
        describe("a ConversationViewModel") {
            // MARK: -- when trusting a contact
            context("when trusting a contact") {
                beforeEach {
                    await viewModel.trustContact()
                    
                    await expect {
                        try await mockStorage.read { db in
                            try Contact.fetchOne(db, id: contactPubkey)?.isTrusted
                        }
                    }.toEventually(beTrue())
                }
                
                // MARK: ---- queues a download for pending attachments
                it("queues a download for pending attachments") {
                    await mockJobRunner
                        .verify {
                            $0.add(.any, job: downloadJob(for: .pendingDownload), initialDependencies: [])
                        }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                }
                
                // MARK: ---- queues a download for failed attachments
                it("queues a download for failed attachments") {
                    await mockJobRunner
                        .verify {
                            $0.add(.any, job: downloadJob(for: .failedDownload), initialDependencies: [])
                        }
                        .wasCalled(exactly: 1, timeout: .milliseconds(100))
                }
                
                // MARK: ---- does not queue a download for invalid attachments
                it("does not queue a download for invalid attachments") {
                    await mockJobRunner
                        .verify {
                            $0.add(.any, job: downloadJob(for: .invalid), initialDependencies: [])
                        }
                        .wasNotCalled(timeout: .milliseconds(100))
                }
                
                // MARK: ---- does not queue a download for downloaded attachments
                it("does not queue a download for downloaded attachments") {
                    await mockJobRunner
                        .verify {
                            $0.add(.any, job: downloadJob(for: .downloaded), initialDependencies: [])
                        }
                        .wasNotCalled(timeout: .milliseconds(100))
                }
            }
        }
    }
}
