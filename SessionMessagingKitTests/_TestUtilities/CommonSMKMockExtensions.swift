// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

@testable import SessionMessagingKit

extension Message.Destination: Mocked {
    static var mock: Message.Destination = .contact(publicKey: "")
}

extension LibSession.Config: Mocked {
    static var mock: LibSession.Config = {
        var conf = config_object()
        return withUnsafeMutablePointer(to: &conf) { .contacts($0) }
    }()
}

extension ConfigDump.Variant: Mocked {
    static var mock: ConfigDump.Variant = .userProfile
}

extension LibSession.CacheBehaviour: Mocked {
    static var mock: LibSession.CacheBehaviour = .skipAutomaticConfigSync
}

extension SessionThread: Mocked {
    static var mock: SessionThread = SessionThread(
        id: .mock,
        variant: .contact,
        creationDateTimestamp: 0,
        shouldBeVisible: false,
        isPinned: false,
        messageDraft: nil,
        notificationSound: nil,
        mutedUntilTimestamp: nil,
        onlyNotifyForMentions: false,
        markedAsUnread: nil,
        pinnedPriority: nil,
        using: .any
    )
}

extension SessionThread.Variant: Mocked {
    static var mock: SessionThread.Variant = .contact
}

extension Interaction: Mocked {
    static var mock: Interaction = Interaction(
        id: 123456,
        serverHash: .mock,
        messageUuid: nil,
        threadId: .mock,
        authorId: .mock,
        variant: .standardIncoming,
        body: .mock,
        timestampMs: 1234567890,
        receivedAtTimestampMs: 1234567890,
        wasRead: false,
        hasMention: false,
        expiresInSeconds: nil,
        expiresStartedAtMs: nil,
        linkPreviewUrl: nil,
        openGroupServerMessageId: nil,
        openGroupWhisper: false,
        openGroupWhisperMods: false,
        openGroupWhisperTo: nil,
        state: .sent,
        recipientReadTimestampMs: nil,
        mostRecentFailureText: nil,
        transientDependencies: nil
    )
}
