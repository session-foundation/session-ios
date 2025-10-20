// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUIKit
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

class NotificationsManagerSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies(
            initialState: {
                $0.dateNow = Date(timeIntervalSince1970: 1234567890)
            }
        )
        @TestState(cache: .libSession, in: dependencies) var mockLibSessionCache: MockLibSessionCache! = MockLibSessionCache(
            initialSetup: {
                $0.defaultInitialSetup()
                $0.when {
                    $0.conversationLastRead(
                        threadId: .any,
                        threadVariant: .any,
                        openGroupUrlInfo: .any
                    )
                }.thenReturn(1234567800)
            }
        )
        @TestState(singleton: .extensionHelper, in: dependencies) var mockExtensionHelper: MockExtensionHelper! = MockExtensionHelper(
            initialSetup: { helper in
                helper.when { $0.hasDedupeRecordSinceLastCleared(threadId: .any) }.thenReturn(false)
            }
        )
        @TestState(singleton: .notificationsManager, in: dependencies) var mockNotificationsManager: MockNotificationsManager! = MockNotificationsManager(
            initialSetup: { $0.defaultInitialSetup() }
        )
        @TestState var message: Message! = VisibleMessage(
            sender: "05\(TestConstants.publicKey.replacingOccurrences(of: "1", with: "2"))",
            sentTimestampMs: 1234567892,
            text: "Test"
        )
        @TestState var threadId: String! = "05\(TestConstants.publicKey.replacingOccurrences(of: "1", with: "2"))"
        @TestState var notificationSettings: Preferences.NotificationSettings! = Preferences.NotificationSettings(
            previewType: .nameAndPreview,
            sound: .defaultNotificationSound,
            mentionsOnly: false,
            mutedUntil: nil
        )
        
        // MARK: - a NotificationsManager - Ensure Should Show
        describe("a NotificationsManager when ensuring we should show notifications") {
            // MARK: -- throws if the message has no sender
            it("throws if the message has no sender") {
                message = VisibleMessage(
                    sentTimestampMs: message.sentTimestampMs,
                    text: "Test"
                )
                
                expect {
                    try mockNotificationsManager.ensureWeShouldShowNotification(
                        message: message,
                        threadId: threadId,
                        threadVariant: .contact,
                        interactionVariant: .standardIncoming,
                        isMessageRequest: false,
                        notificationSettings: notificationSettings,
                        openGroupUrlInfo: nil,
                        currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                        shouldShowForMessageRequest: { true },
                        using: dependencies
                    )
                }.to(throwError(MessageReceiverError.invalidSender))
            }
            
            // MARK: -- throws if the message was sent to note to self
            it("throws if the message was sent to note to self") {
                expect {
                    try mockNotificationsManager.ensureWeShouldShowNotification(
                        message: message,
                        threadId: "05\(TestConstants.publicKey)",
                        threadVariant: .contact,
                        interactionVariant: .standardIncoming,
                        isMessageRequest: false,
                        notificationSettings: notificationSettings,
                        openGroupUrlInfo: nil,
                        currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                        shouldShowForMessageRequest: { true },
                        using: dependencies
                    )
                }.to(throwError(MessageReceiverError.selfSend))
            }
            
            // MARK: -- throws if the message was sent by the current user
            it("throws if the message was sent by the current user") {
                message = VisibleMessage(
                    sender: "05\(TestConstants.publicKey)",
                    sentTimestampMs: message.sentTimestampMs,
                    text: "Test"
                )
                
                expect {
                    try mockNotificationsManager.ensureWeShouldShowNotification(
                        message: message,
                        threadId: threadId,
                        threadVariant: .contact,
                        interactionVariant: .standardIncoming,
                        isMessageRequest: false,
                        notificationSettings: notificationSettings,
                        openGroupUrlInfo: nil,
                        currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                        shouldShowForMessageRequest: { true },
                        using: dependencies
                    )
                }.to(throwError(MessageReceiverError.selfSend))
            }
            
            // MARK: -- throws if notifications are muted
            it("throws if notifications are muted") {
                expect {
                    try mockNotificationsManager.ensureWeShouldShowNotification(
                        message: message,
                        threadId: threadId,
                        threadVariant: .contact,
                        interactionVariant: .standardIncoming,
                        isMessageRequest: false,
                        notificationSettings: Preferences.NotificationSettings(
                            previewType: .nameAndPreview,
                            sound: .defaultNotificationSound,
                            mentionsOnly: false,
                            mutedUntil: Date(timeIntervalSince1970: 1234567891).timeIntervalSince1970
                        ),
                        openGroupUrlInfo: nil,
                        currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                        shouldShowForMessageRequest: { true },
                        using: dependencies
                    )
                }.to(throwError(MessageReceiverError.ignorableMessage))
            }
            
            // MARK: -- throws if the message is not an incoming message
            it("throws if the message is not an incoming message") {
                expect {
                    try mockNotificationsManager.ensureWeShouldShowNotification(
                        message: message,
                        threadId: threadId,
                        threadVariant: .contact,
                        interactionVariant: .standardIncomingDeleted,
                        isMessageRequest: false,
                        notificationSettings: notificationSettings,
                        openGroupUrlInfo: nil,
                        currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                        shouldShowForMessageRequest: { true },
                        using: dependencies
                    )
                }.to(throwError(MessageReceiverError.ignorableMessage))
            }
            
            // MARK: -- for mentions only
            context("for mentions only") {
                beforeEach {
                    notificationSettings = Preferences.NotificationSettings(
                        previewType: .nameAndPreview,
                        sound: .defaultNotificationSound,
                        mentionsOnly: true,
                        mutedUntil: nil
                    )
                }
                
                // MARK: ---- throws if the user is not mentioned
                it("throws if the user is not mentioned") {
                    expect {
                        try mockNotificationsManager.ensureWeShouldShowNotification(
                            message: message,
                            threadId: threadId,
                            threadVariant: .contact,
                            interactionVariant: .standardIncoming,
                            isMessageRequest: false,
                            notificationSettings: notificationSettings,
                            openGroupUrlInfo: nil,
                            currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                            shouldShowForMessageRequest: { true },
                            using: dependencies
                        )
                    }.to(throwError(MessageReceiverError.ignorableMessage))
                }
                
                // MARK: ---- does not throw if the current user is mentioned
                it("does not throw if the current user is mentioned") {
                    message = VisibleMessage(
                        sender: message.sender,
                        sentTimestampMs: message.sentTimestampMs,
                        text: "Test @05\(TestConstants.publicKey)"
                    )
                    
                    expect {
                        try mockNotificationsManager.ensureWeShouldShowNotification(
                            message: message,
                            threadId: threadId,
                            threadVariant: .contact,
                            interactionVariant: .standardIncoming,
                            isMessageRequest: false,
                            notificationSettings: notificationSettings,
                            openGroupUrlInfo: nil,
                            currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                            shouldShowForMessageRequest: { true },
                            using: dependencies
                        )
                    }.toNot(throwError())
                }
                
                // MARK: ---- does not throw if the message quoted a message sent by the current user
                it("does not throw if the message quoted a message sent by the current user") {
                    message = VisibleMessage(
                        sender: message.sender,
                        sentTimestampMs: message.sentTimestampMs,
                        text: "Test",
                        quote: VisibleMessage.VMQuote(
                            timestamp: 1234567880,
                            authorId: "05\(TestConstants.publicKey)"
                        )
                    )
                    
                    expect {
                        try mockNotificationsManager.ensureWeShouldShowNotification(
                            message: message,
                            threadId: threadId,
                            threadVariant: .contact,
                            interactionVariant: .standardIncoming,
                            isMessageRequest: false,
                            notificationSettings: notificationSettings,
                            openGroupUrlInfo: nil,
                            currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                            shouldShowForMessageRequest: { true },
                            using: dependencies
                        )
                    }.toNot(throwError())
                }
            }
            
            // MARK: -- for reactions
            context("for reactions") {
                beforeEach {
                    message = VisibleMessage(
                        sender: message.sender,
                        sentTimestampMs: message.sentTimestampMs,
                        text: nil,
                        reaction: VisibleMessage.VMReaction(
                            timestamp: 1234567880,
                            publicKey: "05\(TestConstants.publicKey)",
                            emoji: "A",
                            kind: .react
                        )
                    )
                }
                
                // MARK: ---- throws if the message was a reaction sent to a non contact conversation
                it("throws if the message was a reaction sent to a non contact conversation") {
                    expect {
                        try mockNotificationsManager.ensureWeShouldShowNotification(
                            message: message,
                            threadId: threadId,
                            threadVariant: .contact,
                            interactionVariant: .standardIncoming,
                            isMessageRequest: false,
                            notificationSettings: Preferences.NotificationSettings(
                                previewType: .nameAndPreview,
                                sound: .defaultNotificationSound,
                                mentionsOnly: false,
                                mutedUntil: nil
                            ),
                            openGroupUrlInfo: nil,
                            currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                            shouldShowForMessageRequest: { true },
                            using: dependencies
                        )
                    }.toNot(throwError())
                    expect {
                        try mockNotificationsManager.ensureWeShouldShowNotification(
                            message: message,
                            threadId: threadId,
                            threadVariant: .legacyGroup,
                            interactionVariant: .standardIncoming,
                            isMessageRequest: false,
                            notificationSettings: Preferences.NotificationSettings(
                                previewType: .nameAndPreview,
                                sound: .defaultNotificationSound,
                                mentionsOnly: false,
                                mutedUntil: nil
                            ),
                            openGroupUrlInfo: nil,
                            currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                            shouldShowForMessageRequest: { true },
                            using: dependencies
                        )
                    }.to(throwError(MessageReceiverError.ignorableMessage))
                    expect {
                        try mockNotificationsManager.ensureWeShouldShowNotification(
                            message: message,
                            threadId: "03\(TestConstants.publicKey.replacingOccurrences(of: "1", with: "2"))",
                            threadVariant: .group,
                            interactionVariant: .standardIncoming,
                            isMessageRequest: false,
                            notificationSettings: Preferences.NotificationSettings(
                                previewType: .nameAndPreview,
                                sound: .defaultNotificationSound,
                                mentionsOnly: false,
                                mutedUntil: nil
                            ),
                            openGroupUrlInfo: nil,
                            currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                            shouldShowForMessageRequest: { true },
                            using: dependencies
                        )
                    }.to(throwError(MessageReceiverError.ignorableMessage))
                    expect {
                        try mockNotificationsManager.ensureWeShouldShowNotification(
                            message: message,
                            threadId: "https://open.getsession.org.test",
                            threadVariant: .community,
                            interactionVariant: .standardIncoming,
                            isMessageRequest: false,
                            notificationSettings: Preferences.NotificationSettings(
                                previewType: .nameAndPreview,
                                sound: .defaultNotificationSound,
                                mentionsOnly: false,
                                mutedUntil: nil
                            ),
                            openGroupUrlInfo: nil,
                            currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                            shouldShowForMessageRequest: { true },
                            using: dependencies
                        )
                    }.to(throwError(MessageReceiverError.ignorableMessage))
                }
            }
            
            // MARK: -- for call messages
            context("for call messages") {
                beforeEach {
                    message = CallMessage(
                        uuid: "1234",
                        kind: .preOffer,
                        sdps: [],
                        state: .missed,
                        sentTimestampMs: message.sentTimestampMs,
                        sender: message.sender
                    )
                }
                
                // MARK: ---- throws if the message was sent to a non contact conversation
                it("throws if the message was sent to a non contact conversation") {
                    expect {
                        try mockNotificationsManager.ensureWeShouldShowNotification(
                            message: message,
                            threadId: threadId,
                            threadVariant: .contact,
                            interactionVariant: .standardIncoming,
                            isMessageRequest: false,
                            notificationSettings: notificationSettings,
                            openGroupUrlInfo: nil,
                            currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                            shouldShowForMessageRequest: { true },
                            using: dependencies
                        )
                    }.toNot(throwError())
                    expect {
                        try mockNotificationsManager.ensureWeShouldShowNotification(
                            message: message,
                            threadId: threadId,
                            threadVariant: .legacyGroup,
                            interactionVariant: .standardIncoming,
                            isMessageRequest: false,
                            notificationSettings: notificationSettings,
                            openGroupUrlInfo: nil,
                            currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                            shouldShowForMessageRequest: { true },
                            using: dependencies
                        )
                    }.to(throwError(MessageReceiverError.invalidMessage))
                    expect {
                        try mockNotificationsManager.ensureWeShouldShowNotification(
                            message: message,
                            threadId: "03\(TestConstants.publicKey.replacingOccurrences(of: "1", with: "2"))",
                            threadVariant: .group,
                            interactionVariant: .standardIncoming,
                            isMessageRequest: false,
                            notificationSettings: notificationSettings,
                            openGroupUrlInfo: nil,
                            currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                            shouldShowForMessageRequest: { true },
                            using: dependencies
                        )
                    }.to(throwError(MessageReceiverError.invalidMessage))
                    expect {
                        try mockNotificationsManager.ensureWeShouldShowNotification(
                            message: message,
                            threadId: "https://open.getsession.org.test",
                            threadVariant: .community,
                            interactionVariant: .standardIncoming,
                            isMessageRequest: false,
                            notificationSettings: notificationSettings,
                            openGroupUrlInfo: nil,
                            currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                            shouldShowForMessageRequest: { true },
                            using: dependencies
                        )
                    }.to(throwError(MessageReceiverError.invalidMessage))
                }
                
                // MARK: ---- throws if the message is not a preOffer
                it("throws if the message is not a preOffer") {
                    message = CallMessage(
                        uuid: "1234",
                        kind: .offer,
                        sdps: [],
                        sentTimestampMs: message.sentTimestampMs,
                        sender: message.sender
                    )
                    
                    expect {
                        try mockNotificationsManager.ensureWeShouldShowNotification(
                            message: message,
                            threadId: threadId,
                            threadVariant: .contact,
                            interactionVariant: .standardIncoming,
                            isMessageRequest: false,
                            notificationSettings: notificationSettings,
                            openGroupUrlInfo: nil,
                            currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                            shouldShowForMessageRequest: { true },
                            using: dependencies
                        )
                    }.to(throwError(MessageReceiverError.ignorableMessage))
                }
                
                // MARK: ---- throws for the expected states
                it("throws for the expected states") {
                    let nonThrowingStates: Set<CallMessage.MessageInfo.State> = [
                        .missed, .permissionDenied, .permissionDeniedMicrophone
                    ]
                    let stateToError: [String: String] = CallMessage.MessageInfo.State.allCases
                        .filter { !nonThrowingStates.contains($0) }
                        .reduce(into: [:]) { result, next in
                            result["\(next)"] = "\(MessageReceiverError.ignorableMessage)"
                        }
                    var result: [String: String] = [:]
                    
                    CallMessage.MessageInfo.State.allCases.forEach { state in
                        do {
                            try mockNotificationsManager.ensureWeShouldShowNotification(
                                message: CallMessage(
                                    uuid: "1234",
                                    kind: .preOffer,
                                    sdps: [],
                                    state: state,
                                    sentTimestampMs: message.sentTimestampMs,
                                    sender: message.sender
                                ),
                                threadId: threadId,
                                threadVariant: .contact,
                                interactionVariant: .standardIncoming,
                                isMessageRequest: false,
                                notificationSettings: notificationSettings,
                                openGroupUrlInfo: nil,
                                currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                                shouldShowForMessageRequest: { true },
                                using: dependencies
                            )
                        }
                        catch { result["\(state)"] = "\(error)" }
                    }
                    expect(result).to(equal(stateToError))
                }
            }
            
            // MARK: -- does not throw for a group invitation
            it("does not throw for a group invitation") {
                expect {
                    message = GroupUpdateInviteMessage(
                        inviteeSessionIdHexString: "",
                        groupSessionId: SessionId(.standard, hex: TestConstants.publicKey),
                        groupName: "TestName",
                        memberAuthData: Data([1, 2, 3]),
                        adminSignature: Authentication.Signature.standard(signature: [1, 2, 3]),
                        sentTimestampMs: message.sentTimestampMs,
                        sender: message.sender
                    )
                    try mockNotificationsManager.ensureWeShouldShowNotification(
                        message: message,
                        threadId: threadId,
                        threadVariant: .contact,
                        interactionVariant: .standardIncoming,
                        isMessageRequest: false,
                        notificationSettings: notificationSettings,
                        openGroupUrlInfo: nil,
                        currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                        shouldShowForMessageRequest: { true },
                        using: dependencies
                    )
                }.toNot(throwError())
            }
            
            // MARK: -- does not throw for a group promotion
            it("does not throw for a group promotion") {
                expect {
                    message = GroupUpdatePromoteMessage(
                        groupIdentitySeed: Data([1, 2, 3]),
                        groupName: "TestName",
                        profile: nil,
                        sentTimestampMs: message.sentTimestampMs,
                        sender: message.sender
                    )
                    try mockNotificationsManager.ensureWeShouldShowNotification(
                        message: message,
                        threadId: threadId,
                        threadVariant: .contact,
                        interactionVariant: .standardIncoming,
                        isMessageRequest: false,
                        notificationSettings: notificationSettings,
                        openGroupUrlInfo: nil,
                        currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                        shouldShowForMessageRequest: { true },
                        using: dependencies
                    )
                }.toNot(throwError())
            }
            
            // MARK: -- throws for the expected message types
            it("throws for the expected message types") {
                let nonThrowingMessageTypes: [Message.Type] = [
                    VisibleMessage.self, CallMessage.self, GroupUpdateInviteMessage.self, GroupUpdatePromoteMessage.self
                ]
                let throwingMessages: [Message] = [
                    ReadReceipt(timestamps: [], sender: message.sender),
                    TypingIndicator(kind: .started, sender: message.sender),
                    DataExtractionNotification(kind: .mediaSaved(timestamp: 0), sender: message.sender),
                    ExpirationTimerUpdate(sender: message.sender),
                    UnsendRequest(timestamp: 0, author: "", sender: message.sender),
                    MessageRequestResponse(isApproved: false, sender: message.sender),
                    GroupUpdateInfoChangeMessage(
                        changeType: .name,
                        adminSignature: Authentication.Signature.standard(signature: [1, 2, 3]),
                        sender: message.sender
                    ),
                    GroupUpdateMemberChangeMessage(
                        changeType: .added,
                        memberSessionIds: [],
                        historyShared: false,
                        adminSignature: Authentication.Signature.standard(signature: [1, 2, 3]),
                        sender: message.sender
                    ),
                    GroupUpdateMemberLeftMessage(sender: message.sender),
                    GroupUpdateMemberLeftNotificationMessage(sender: message.sender),
                    GroupUpdateInviteResponseMessage(isApproved: false, sender: message.sender),
                    GroupUpdateDeleteMemberContentMessage(
                        memberSessionIds: [],
                        messageHashes: [],
                        adminSignature: nil,
                        sender: message.sender
                    ),
                    LibSessionMessage(ciphertext: Data([1, 2, 3]), sender: message.sender)
                ]
                
                /// If this line fails then we need to create a new message type in one of the above arrays
                expect(Message.Variant.allCases.count - nonThrowingMessageTypes.count).to(equal(throwingMessages.count))
                let messageTypeNameToError: [String: String] = throwingMessages
                    .reduce(into: [:]) { result, next in
                        result["\(type(of: next))"] = "\(MessageReceiverError.ignorableMessage)"
                    }
                var result: [String: String] = [:]
                
                throwingMessages.forEach { throwingMessage in
                    do {
                        try mockNotificationsManager.ensureWeShouldShowNotification(
                            message: throwingMessage,
                            threadId: threadId,
                            threadVariant: .contact,
                            interactionVariant: .standardIncoming,
                            isMessageRequest: false,
                            notificationSettings: notificationSettings,
                            openGroupUrlInfo: nil,
                            currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                            shouldShowForMessageRequest: { true },
                            using: dependencies
                        )
                    }
                    catch { result["\(type(of: throwingMessage))"] = "\(error)" }
                }
                expect(result).to(equal(messageTypeNameToError))
            }
            
            // MARK: -- throws if the sender is blocked
            it("throws if the sender is blocked") {
                expect {
                    mockLibSessionCache
                        .when { $0.isContactBlocked(contactId: .any) }
                        .thenReturn(true)
                    
                    try mockNotificationsManager.ensureWeShouldShowNotification(
                        message: message,
                        threadId: threadId,
                        threadVariant: .contact,
                        interactionVariant: .standardIncoming,
                        isMessageRequest: false,
                        notificationSettings: notificationSettings,
                        openGroupUrlInfo: nil,
                        currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                        shouldShowForMessageRequest: { true },
                        using: dependencies
                    )
                }.to(throwError(MessageReceiverError.senderBlocked))
            }
            
            // MARK: -- throws if the message was already read
            it("throws if the message was already read") {
                expect {
                    mockLibSessionCache
                        .when {
                            $0.conversationLastRead(
                                threadId: .any,
                                threadVariant: .any,
                                openGroupUrlInfo: .any
                            )
                        }
                        .thenReturn(1234567899)
                    
                    try mockNotificationsManager.ensureWeShouldShowNotification(
                        message: message,
                        threadId: threadId,
                        threadVariant: .contact,
                        interactionVariant: .standardIncoming,
                        isMessageRequest: false,
                        notificationSettings: notificationSettings,
                        openGroupUrlInfo: nil,
                        currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                        shouldShowForMessageRequest: { true },
                        using: dependencies
                    )
                }.to(throwError(MessageReceiverError.ignorableMessage))
            }
            
            // MARK: -- throws if the message was sent to a message request and we should not show
            it("throws if the message was sent to a message request and we should not show") {
                expect {
                    try mockNotificationsManager.ensureWeShouldShowNotification(
                        message: message,
                        threadId: threadId,
                        threadVariant: .contact,
                        interactionVariant: .standardIncoming,
                        isMessageRequest: true,
                        notificationSettings: notificationSettings,
                        openGroupUrlInfo: nil,
                        currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                        shouldShowForMessageRequest: { false },
                        using: dependencies
                    )
                }.to(throwError(MessageReceiverError.ignorableMessageRequestMessage))
            }
            
            // MARK: -- does not throw if the message was sent to a message request and we should show
            it("does not throw if the message was sent to a message request and we should show") {
                expect {
                    try mockNotificationsManager.ensureWeShouldShowNotification(
                        message: message,
                        threadId: threadId,
                        threadVariant: .contact,
                        interactionVariant: .standardIncoming,
                        isMessageRequest: true,
                        notificationSettings: notificationSettings,
                        openGroupUrlInfo: nil,
                        currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                        shouldShowForMessageRequest: { true },
                        using: dependencies
                    )
                }.toNot(throwError())
            }
            
            // MARK: -- does not throw if the conversation type does not support message requests
            it("does not throw if the conversation type does not support message requests") {
                expect {
                    try mockNotificationsManager.ensureWeShouldShowNotification(
                        message: message,
                        threadId: threadId,
                        threadVariant: .legacyGroup,
                        interactionVariant: .standardIncoming,
                        isMessageRequest: true,
                        notificationSettings: notificationSettings,
                        openGroupUrlInfo: nil,
                        currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                        shouldShowForMessageRequest: { false },
                        using: dependencies
                    )
                }.toNot(throwError())
                expect {
                    try mockNotificationsManager.ensureWeShouldShowNotification(
                        message: message,
                        threadId: "https://open.getsession.org.test",
                        threadVariant: .community,
                        interactionVariant: .standardIncoming,
                        isMessageRequest: true,
                        notificationSettings: notificationSettings,
                        openGroupUrlInfo: nil,
                        currentUserSessionIds: ["05\(TestConstants.publicKey)"],
                        shouldShowForMessageRequest: { false },
                        using: dependencies
                    )
                }.toNot(throwError())
            }
        }
        
        // MARK: - a NotificationsManager - Notification Title
        describe("a NotificationsManager when generating the notification title") {
            // MARK: -- returns the app name if we should not show a name
            it("returns the app name if we should not show a name") {
                notificationSettings = Preferences.NotificationSettings(
                    previewType: .noNameNoPreview,
                    sound: .defaultNotificationSound,
                    mentionsOnly: false,
                    mutedUntil: nil
                )
                
                expect {
                    try mockNotificationsManager.notificationTitle(
                        cat: .mock,
                        message: message,
                        threadId: threadId,
                        threadVariant: .contact,
                        isMessageRequest: false,
                        notificationSettings: notificationSettings,
                        displayNameRetriever: { _, _ in nil },
                        groupNameRetriever: { _, _ in nil },
                        using: dependencies
                    )
                }.to(equal(Constants.app_name))
            }
            
            // MARK: -- returns the app name if the message is for a message request
            it("returns the app name if the message is for a message request") {
                expect {
                    try mockNotificationsManager.notificationTitle(
                        cat: .mock,
                        message: message,
                        threadId: threadId,
                        threadVariant: .contact,
                        isMessageRequest: true,
                        notificationSettings: notificationSettings,
                        displayNameRetriever: { _, _ in nil },
                        groupNameRetriever: { _, _ in nil },
                        using: dependencies
                    )
                }.to(equal(Constants.app_name))
            }
            
            // MARK: -- returns the app name if there is no sender
            it("returns the app name if there is no sender") {
                message.sender = nil
                
                expect {
                    try mockNotificationsManager.notificationTitle(
                        cat: .mock,
                        message: message,
                        threadId: threadId,
                        threadVariant: .contact,
                        isMessageRequest: false,
                        notificationSettings: notificationSettings,
                        displayNameRetriever: { _, _ in nil },
                        groupNameRetriever: { _, _ in nil },
                        using: dependencies
                    )
                }.to(equal(Constants.app_name))
            }
            
            // MARK: -- returns the name returned by the displayNameRetriever
            it("returns the name returned by the displayNameRetriever") {
                expect {
                    try mockNotificationsManager.notificationTitle(
                        cat: .mock,
                        message: message,
                        threadId: threadId,
                        threadVariant: .contact,
                        isMessageRequest: false,
                        notificationSettings: notificationSettings,
                        displayNameRetriever: { _, _ in "TestName" },
                        groupNameRetriever: { _, _ in nil },
                        using: dependencies
                    )
                }.to(equal("TestName"))
            }
            
            // MARK: -- returns the truncated sender id when the displayNameRetriever returns null
            it("returns the truncated sender id when the displayNameRetriever returns null") {
                expect {
                    try mockNotificationsManager.notificationTitle(
                        cat: .mock,
                        message: message,
                        threadId: threadId,
                        threadVariant: .contact,
                        isMessageRequest: false,
                        notificationSettings: notificationSettings,
                        displayNameRetriever: { _, _ in nil },
                        groupNameRetriever: { _, _ in nil },
                        using: dependencies
                    )
                }.to(equal("0588...c65b"))
            }
            
            [SessionThread.Variant.group, SessionThread.Variant.community].forEach { variant in
                // MARK: -- when sent to a X
                context("when sent to a \(variant)") {
                    // MARK: ---- returns the formatted string containing the retrieved name and group name
                    it("returns the formatted string containing the retrieved name and group name") {
                        expect {
                            try mockNotificationsManager.notificationTitle(
                                cat: .mock,
                                message: message,
                                threadId: threadId,
                                threadVariant: variant,
                                isMessageRequest: false,
                                notificationSettings: notificationSettings,
                                displayNameRetriever: { _, _ in "TestName" },
                                groupNameRetriever: { _, _ in "TestGroup" },
                                using: dependencies
                            )
                        }.to(equal(
                            "notificationsIosGroup"
                                .put(key: "name", value: "TestName")
                                .put(key: "conversation_name", value: "TestGroup")
                                .localized()
                        ))
                    }
                    
                    // MARK: ---- returns the formatted string containing the truncated id and group name when the displayNameRetriever returns null
                    it("returns the formatted string containing the truncated id and group name when the displayNameRetriever returns null") {
                        mockLibSessionCache.when { $0.groupName(groupSessionId: .any) }.thenReturn("TestGroup")
                        
                        expect {
                            try mockNotificationsManager.notificationTitle(
                                cat: .mock,
                                message: message,
                                threadId: threadId,
                                threadVariant: variant,
                                isMessageRequest: false,
                                notificationSettings: notificationSettings,
                                displayNameRetriever: { _, _ in nil },
                                groupNameRetriever: { _, _ in "TestGroup" },
                                using: dependencies
                            )
                        }.to(equal(
                            "notificationsIosGroup"
                                .put(key: "name", value: "0588...c65b")
                                .put(key: "conversation_name", value: "TestGroup")
                                .localized()
                        ))
                    }
                    
                    // MARK: ---- returns the formatted string containing the retrieved name and default group name when the retriever fails to return a group name
                    it("returns the formatted string containing the retrieved name and default group name when the retriever fails to return a group name") {
                        expect {
                            try mockNotificationsManager.notificationTitle(
                                cat: .mock,
                                message: message,
                                threadId: threadId,
                                threadVariant: variant,
                                isMessageRequest: false,
                                notificationSettings: notificationSettings,
                                displayNameRetriever: { _, _ in "TestName" },
                                groupNameRetriever: { _, _ in nil },
                                using: dependencies
                            )
                        }.to(equal(
                            "notificationsIosGroup"
                                .put(key: "name", value: "TestName")
                                .put(key: "conversation_name", value: "groupUnknown".localized())
                                .localized()
                        ))
                    }
                }
            }
            
            // MARK: -- throws for legacy groups
            it("throws for legacy groups") {
                expect {
                    try mockNotificationsManager.notificationTitle(
                        cat: .mock,
                        message: message,
                        threadId: threadId,
                        threadVariant: .legacyGroup,
                        isMessageRequest: false,
                        notificationSettings: notificationSettings,
                        displayNameRetriever: { _, _ in nil },
                        groupNameRetriever: { _, _ in nil },
                        using: dependencies
                    )
                }.to(throwError(MessageReceiverError.ignorableMessage))
            }
        }
        
        // MARK: - a NotificationsManager - Notification Body
        describe("a NotificationsManager when generating the notification body") {
            // MARK: -- returns the expected string for a message request
            it("returns the expected string for a message request") {
                expect {
                    mockNotificationsManager.notificationBody(
                        cat: .mock,
                        message: message,
                        threadVariant: .contact,
                        isMessageRequest: true,
                        notificationSettings: notificationSettings,
                        interactionVariant: .standardIncoming,
                        attachmentDescriptionInfo: nil,
                        currentUserSessionIds: [],
                        displayNameRetriever: { _, _ in nil },
                        using: dependencies
                    )
                }.to(equal("messageRequestsNew".localized()))
            }
            
            // MARK: -- returns a generic message when there is no sender
            it("returns a generic message when there is no sender") {
                message.sender = nil
                
                expect {
                    mockNotificationsManager.notificationBody(
                        cat: .mock,
                        message: message,
                        threadVariant: .contact,
                        isMessageRequest: false,
                        notificationSettings: notificationSettings,
                        interactionVariant: .standardIncoming,
                        attachmentDescriptionInfo: nil,
                        currentUserSessionIds: [],
                        displayNameRetriever: { _, _ in nil },
                        using: dependencies
                    )
                }.to(equal("messageNewYouveGot".putNumber(1).localized()))
            }
            
            // MARK: -- returns a generic message when the preview type does not include the body
            it("returns a generic message when the preview type does not include the body") {
                expect {
                    mockNotificationsManager.notificationBody(
                        cat: .mock,
                        message: message,
                        threadVariant: .contact,
                        isMessageRequest: false,
                        notificationSettings: Preferences.NotificationSettings(
                            previewType: .nameNoPreview,
                            sound: .defaultNotificationSound,
                            mentionsOnly: false,
                            mutedUntil: nil
                        ),
                        interactionVariant: .standardIncoming,
                        attachmentDescriptionInfo: nil,
                        currentUserSessionIds: [],
                        displayNameRetriever: { _, _ in nil },
                        using: dependencies
                    )
                }.to(equal("messageNewYouveGot".putNumber(1).localized()))
                expect {
                    mockNotificationsManager.notificationBody(
                        cat: .mock,
                        message: message,
                        threadVariant: .contact,
                        isMessageRequest: false,
                        notificationSettings: Preferences.NotificationSettings(
                            previewType: .noNameNoPreview,
                            sound: .defaultNotificationSound,
                            mentionsOnly: false,
                            mutedUntil: nil
                        ),
                        interactionVariant: .standardIncoming,
                        attachmentDescriptionInfo: nil,
                        currentUserSessionIds: [],
                        displayNameRetriever: { _, _ in nil },
                        using: dependencies
                    )
                }.to(equal("messageNewYouveGot".putNumber(1).localized()))
            }
            
            // MARK: -- returns the expected reaction message when there is a reaction
            it("returns the expected reaction message when there is a reaction") {
                message = VisibleMessage(
                    sender: "05\(TestConstants.publicKey.replacingOccurrences(of: "1", with: "2"))",
                    text: nil,
                    reaction: VisibleMessage.VMReaction(
                        timestamp: 1234567880,
                        publicKey: "05\(TestConstants.publicKey)",
                        emoji: "A",
                        kind: .react
                    )
                )
                
                expect {
                    mockNotificationsManager.notificationBody(
                        cat: .mock,
                        message: message,
                        threadVariant: .contact,
                        isMessageRequest: false,
                        notificationSettings: notificationSettings,
                        interactionVariant: .standardIncoming,
                        attachmentDescriptionInfo: nil,
                        currentUserSessionIds: [],
                        displayNameRetriever: { _, _ in nil },
                        using: dependencies
                    )
                }.to(equal("emojiReactsNotification".put(key: "emoji", value: "A").localized()))
            }
            
            // MARK: -- returns the message preview text for a visible message
            it("returns the message preview text for a visible message") {
                expect {
                    mockNotificationsManager.notificationBody(
                        cat: .mock,
                        message: message,
                        threadVariant: .contact,
                        isMessageRequest: false,
                        notificationSettings: notificationSettings,
                        interactionVariant: .standardIncoming,
                        attachmentDescriptionInfo: nil,
                        currentUserSessionIds: [],
                        displayNameRetriever: { _, _ in nil },
                        using: dependencies
                    )
                }.to(equal("Test"))
            }
            
            // MARK: -- resolves a mention that is not the sender
            it("resolves a mention that is not the sender") {
                message = VisibleMessage(
                    sender: "05\(TestConstants.publicKey.replacingOccurrences(of: "1", with: "2"))",
                    text: "Hey @05\(TestConstants.publicKey.replacingOccurrences(of: "1", with: "3"))",
                    profile: VisibleMessage.VMProfile(displayName: "TestSender")
                )
                
                expect {
                    mockNotificationsManager.notificationBody(
                        cat: .mock,
                        message: message,
                        threadVariant: .contact,
                        isMessageRequest: false,
                        notificationSettings: notificationSettings,
                        interactionVariant: .standardIncoming,
                        attachmentDescriptionInfo: nil,
                        currentUserSessionIds: [],
                        displayNameRetriever: { _, _ in "TestMention" },
                        using: dependencies
                    )
                }.to(equal("Hey @TestMention"))
            }
            
            // MARK: -- returns a generic message if no interaction variant is provided
            it("returns a generic message if no interaction variant is provided") {
                expect {
                    mockNotificationsManager.notificationBody(
                        cat: .mock,
                        message: message,
                        threadVariant: .contact,
                        isMessageRequest: false,
                        notificationSettings: notificationSettings,
                        interactionVariant: nil,
                        attachmentDescriptionInfo: nil,
                        currentUserSessionIds: [],
                        displayNameRetriever: { _, _ in nil },
                        using: dependencies
                    )
                }.to(equal("messageNewYouveGot".putNumber(1).localized()))
            }
            
            // MARK: -- for a call message missed due to permissions
            context("for a call message missed due to permissions") {
                beforeEach {
                    message = CallMessage(
                        uuid: "1234",
                        kind: .preOffer,
                        sdps: [],
                        state: .permissionDenied,
                        sender: "05\(TestConstants.publicKey.replacingOccurrences(of: "1", with: "2"))"
                    )
                }
                
                // MARK: ---- returns a missed call message
                it("returns a missed call message") {
                    expect {
                        mockNotificationsManager.notificationBody(
                            cat: .mock,
                            message: message,
                            threadVariant: .contact,
                            isMessageRequest: false,
                            notificationSettings: notificationSettings,
                            interactionVariant: nil,
                            attachmentDescriptionInfo: nil,
                            currentUserSessionIds: [],
                            displayNameRetriever: { _, _ in "TestName" },
                            using: dependencies
                        )
                    }.to(equal("callsYouMissedCallPermissions".put(key: "name", value: "TestName").localizedDeformatted()))
                }
                
                // MARK: ---- includes the senders display name if retrieved
                it("includes the senders display name if retrieved") {
                    expect {
                        mockNotificationsManager.notificationBody(
                            cat: .mock,
                            message: message,
                            threadVariant: .contact,
                            isMessageRequest: false,
                            notificationSettings: notificationSettings,
                            interactionVariant: nil,
                            attachmentDescriptionInfo: nil,
                            currentUserSessionIds: [],
                            displayNameRetriever: { _, _ in "TestName" },
                            using: dependencies
                        )
                    }.to(equal("callsYouMissedCallPermissions".put(key: "name", value: "TestName").localizedDeformatted()))
                }
                
                // MARK: ---- defaults to the truncated id if it cannot retrieve a display name
                it("defaults to the truncated id if it cannot retrieve a display name") {
                    expect {
                        mockNotificationsManager.notificationBody(
                            cat: .mock,
                            message: message,
                            threadVariant: .contact,
                            isMessageRequest: false,
                            notificationSettings: notificationSettings,
                            interactionVariant: nil,
                            attachmentDescriptionInfo: nil,
                            currentUserSessionIds: [],
                            displayNameRetriever: { _, _ in nil },
                            using: dependencies
                        )
                    }.to(equal("callsYouMissedCallPermissions".put(key: "name", value: "0588...c65b").localizedDeformatted()))
                }
            }
            
            // MARK: -- for a missed call message
            context("for a missed call message") {
                beforeEach {
                    message = CallMessage(
                        uuid: "1234",
                        kind: .preOffer,
                        sdps: [],
                        state: .missed,
                        sender: "05\(TestConstants.publicKey.replacingOccurrences(of: "1", with: "2"))"
                    )
                }
                
                // MARK: ---- returns a missed call message
                it("returns a missed call message") {
                    expect {
                        mockNotificationsManager.notificationBody(
                            cat: .mock,
                            message: message,
                            threadVariant: .contact,
                            isMessageRequest: false,
                            notificationSettings: notificationSettings,
                            interactionVariant: nil,
                            attachmentDescriptionInfo: nil,
                            currentUserSessionIds: [],
                            displayNameRetriever: { _, _ in "TestName" },
                            using: dependencies
                        )
                    }.to(equal("callsMissedCallFrom".put(key: "name", value: "TestName").localizedDeformatted()))
                }
                
                // MARK: ---- includes the senders display name if retrieved
                it("includes the senders display name if retrieved") {
                    expect {
                        mockNotificationsManager.notificationBody(
                            cat: .mock,
                            message: message,
                            threadVariant: .contact,
                            isMessageRequest: false,
                            notificationSettings: notificationSettings,
                            interactionVariant: nil,
                            attachmentDescriptionInfo: nil,
                            currentUserSessionIds: [],
                            displayNameRetriever: { _, _ in "TestName" },
                            using: dependencies
                        )
                    }.to(equal(
                        "callsMissedCallFrom"
                            .put(key: "name", value: "TestName")
                            .localizedDeformatted()
                    ))
                }
                
                // MARK: ---- defaults to the truncated id if it cannot retrieve a display name
                it("defaults to the truncated id if it cannot retrieve a display name") {
                    expect {
                        mockNotificationsManager.notificationBody(
                            cat: .mock,
                            message: message,
                            threadVariant: .contact,
                            isMessageRequest: false,
                            notificationSettings: notificationSettings,
                            interactionVariant: nil,
                            attachmentDescriptionInfo: nil,
                            currentUserSessionIds: [],
                            displayNameRetriever: { _, _ in nil },
                            using: dependencies
                        )
                    }.to(equal(
                        "callsMissedCallFrom"
                            .put(key: "name", value: "0588...c65b")
                            .localizedDeformatted()
                    ))
                }
            }
            
            // MARK: -- returns a generic message in all other cases
            it("returns a generic message in all other cases") {
                message = ReadReceipt(timestamps: [], sender: message.sender)
                
                expect {
                    mockNotificationsManager.notificationBody(
                        cat: .mock,
                        message: message,
                        threadVariant: .contact,
                        isMessageRequest: false,
                        notificationSettings: notificationSettings,
                        interactionVariant: .standardIncoming,
                        attachmentDescriptionInfo: nil,
                        currentUserSessionIds: [],
                        displayNameRetriever: { _, _ in nil },
                        using: dependencies
                    )
                }.to(equal("messageNewYouveGot".putNumber(1).localized()))
            }
        }
        
        // MARK: - a NotificationsManager - Notify User
        describe("a NotificationsManager when notifying the user") {
            // MARK: -- checks if the conversation is a message request
            it("checks if the conversation is a message request") {
                expect {
                    try mockNotificationsManager.notifyUser(
                        cat: .mock,
                        message: message,
                        threadId: "05\(TestConstants.publicKey)",
                        threadVariant: .contact,
                        interactionIdentifier: "TestId",
                        interactionVariant: .standardIncoming,
                        attachmentDescriptionInfo: nil,
                        openGroupUrlInfo: nil,
                        applicationState: .background,
                        extensionBaseUnreadCount: 1,
                        currentUserSessionIds: [],
                        displayNameRetriever: { _, _ in nil },
                        groupNameRetriever: { _, _ in nil },
                        shouldShowForMessageRequest: { false }
                    )
                }.toNot(throwError())
                expect(mockLibSessionCache).to(call(.exactly(times: 1), matchingParameters: .all) {
                    $0.isMessageRequest(threadId: "05\(TestConstants.publicKey)", threadVariant: .contact)
                })
            }
            
            // MARK: -- retrieves notification settings from the notification maanager
            it("retrieves notification settings from the notification maanager") {
                expect {
                    try mockNotificationsManager.notifyUser(
                        cat: .mock,
                        message: message,
                        threadId: "05\(TestConstants.publicKey)",
                        threadVariant: .contact,
                        interactionIdentifier: "TestId",
                        interactionVariant: .standardIncoming,
                        attachmentDescriptionInfo: nil,
                        openGroupUrlInfo: nil,
                        applicationState: .background,
                        extensionBaseUnreadCount: 1,
                        currentUserSessionIds: [],
                        displayNameRetriever: { _, _ in nil },
                        groupNameRetriever: { _, _ in nil },
                        shouldShowForMessageRequest: { false }
                    )
                }.toNot(throwError())
                expect(mockNotificationsManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                    $0.settings(threadId: "05\(TestConstants.publicKey)", threadVariant: .contact)
                })
            }
            
            // MARK: -- checks whether it should show for messages requests if the message is a message request
            it("checks whether it should show for messages requests if the message is a message request") {
                var didCallShouldShowForMessageRequest: Bool = false
                mockLibSessionCache
                    .when { $0.isMessageRequest(threadId: .any, threadVariant: .any) }
                    .thenReturn(true)
                
                expect {
                    try mockNotificationsManager.notifyUser(
                        cat: .mock,
                        message: message,
                        threadId: "05\(TestConstants.publicKey)",
                        threadVariant: .contact,
                        interactionIdentifier: "TestId",
                        interactionVariant: .standardIncoming,
                        attachmentDescriptionInfo: nil,
                        openGroupUrlInfo: nil,
                        applicationState: .background,
                        extensionBaseUnreadCount: 1,
                        currentUserSessionIds: [],
                        displayNameRetriever: { _, _ in nil },
                        groupNameRetriever: { _, _ in nil },
                        shouldShowForMessageRequest: {
                            didCallShouldShowForMessageRequest = true
                            return false
                        }
                    )
                }.to(throwError(MessageReceiverError.ignorableMessageRequestMessage))
                expect(didCallShouldShowForMessageRequest).to(beTrue())
            }
            
            // MARK: -- adds the notification request
            it("adds the notification request") {
                expect {
                    try mockNotificationsManager.notifyUser(
                        cat: .mock,
                        message: message,
                        threadId: "05\(TestConstants.publicKey)",
                        threadVariant: .contact,
                        interactionIdentifier: "TestId",
                        interactionVariant: .standardIncoming,
                        attachmentDescriptionInfo: nil,
                        openGroupUrlInfo: nil,
                        applicationState: .background,
                        extensionBaseUnreadCount: 1,
                        currentUserSessionIds: [],
                        displayNameRetriever: { _, _ in nil },
                        groupNameRetriever: { _, _ in nil },
                        shouldShowForMessageRequest: { false }
                    )
                }.toNot(throwError())
                expect(mockNotificationsManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                    $0.addNotificationRequest(
                        content: NotificationContent(
                            threadId: "05\(TestConstants.publicKey)",
                            threadVariant: .contact,
                            identifier: "05\(TestConstants.publicKey)-TestId",
                            category: .incomingMessage,
                            groupingIdentifier: .threadId("05\(TestConstants.publicKey)"),
                            title: "0588...c65b",
                            body: "Test",
                            sound: .note,
                            applicationState: .background
                        ),
                        notificationSettings: Preferences.NotificationSettings(
                            previewType: .nameAndPreview,
                            sound: .defaultNotificationSound,
                            mentionsOnly: false,
                            mutedUntil: nil
                        ),
                        extensionBaseUnreadCount: 1
                    )
                })
            }
            
            // MARK: -- uses a random identifier for reaction notifications
            it("uses a random identifier for reaction notifications") {
                message = VisibleMessage(
                    sender: message.sender,
                    sentTimestampMs: message.sentTimestampMs,
                    text: nil,
                    reaction: VisibleMessage.VMReaction(
                        timestamp: 1234567880,
                        publicKey: "05\(TestConstants.publicKey)",
                        emoji: "A",
                        kind: .react
                    )
                )
                dependencies.uuid = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
                
                expect {
                    try mockNotificationsManager.notifyUser(
                        cat: .mock,
                        message: message,
                        threadId: "05\(TestConstants.publicKey)",
                        threadVariant: .contact,
                        interactionIdentifier: "TestId",
                        interactionVariant: .standardIncoming,
                        attachmentDescriptionInfo: nil,
                        openGroupUrlInfo: nil,
                        applicationState: .background,
                        extensionBaseUnreadCount: 1,
                        currentUserSessionIds: [],
                        displayNameRetriever: { _, _ in nil },
                        groupNameRetriever: { _, _ in nil },
                        shouldShowForMessageRequest: { false }
                    )
                }.toNot(throwError())
                expect(mockNotificationsManager).to(call(.exactly(times: 1), matchingParameters: .all) {
                    $0.addNotificationRequest(
                        content: NotificationContent(
                            threadId: "05\(TestConstants.publicKey)",
                            threadVariant: .contact,
                            identifier: "00000000-0000-0000-0000-000000000001",
                            category: .incomingMessage,
                            groupingIdentifier: .threadId("05\(TestConstants.publicKey)"),
                            title: "0588...c65b",
                            body: "emojiReactsNotification"
                                .put(key: "emoji", value: "A")
                                .localized(),
                            sound: .note,
                            applicationState: .background
                        ),
                        notificationSettings: Preferences.NotificationSettings(
                            previewType: .nameAndPreview,
                            sound: .defaultNotificationSound,
                            mentionsOnly: false,
                            mutedUntil: nil
                        ),
                        extensionBaseUnreadCount: 1
                    )
                })
            }
        }
    }
}
