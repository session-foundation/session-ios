// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUIKit
import SessionUtilitiesKit
import TestUtilities

@testable import SessionMessagingKit

extension Message.Destination: @retroactive Mocked {
    public static var any: Message.Destination = .contact(publicKey: String.any)
    public static var mock: Message.Destination = .contact(publicKey: "")
}

extension LibSession.Config: @retroactive Mocked {
    public static var any: LibSession.Config = .mock
    public static var mock: LibSession.Config = {
        var conf = config_object()
        return withUnsafeMutablePointer(to: &conf) { .contacts($0) }
    }()
}

extension ConfigDump.Variant: @retroactive Mocked {
    public static var any: ConfigDump.Variant = .local
    public static var mock: ConfigDump.Variant = .userProfile
}

extension LibSession.CacheBehaviour: @retroactive Mocked {
    public static var any: LibSession.CacheBehaviour = .skipAutomaticConfigSync
    public static var mock: LibSession.CacheBehaviour = .skipAutomaticConfigSync
}

extension LibSession.OpenGroupUrlInfo: @retroactive Mocked {
    public static var any: LibSession.OpenGroupUrlInfo = LibSession.OpenGroupUrlInfo(
        threadId: .any,
        server: .any,
        roomToken: .any,
        publicKey: .any
    )
    public static var mock: LibSession.OpenGroupUrlInfo = LibSession.OpenGroupUrlInfo(
        threadId: .mock,
        server: .mock,
        roomToken: .mock,
        publicKey: .mock
    )
}

extension SessionThread: @retroactive Mocked {
    public static var any: SessionThread = SessionThread(
        id: .any,
        variant: .any,
        creationDateTimestamp: .any,
        shouldBeVisible: .any,
        isPinned: .any,
        messageDraft: .any,
        notificationSound: .any,
        mutedUntilTimestamp: .any,
        onlyNotifyForMentions: .any,
        markedAsUnread: .any,
        pinnedPriority: .any
    )
    
    public static var mock: SessionThread = SessionThread(
        id: .mock,
        variant: .mock,
        creationDateTimestamp: .mock,
        shouldBeVisible: .mock,
        isPinned: .mock,
        messageDraft: .mock,
        notificationSound: .mock,
        mutedUntilTimestamp: .mock,
        onlyNotifyForMentions: .mock,
        markedAsUnread: .mock,
        pinnedPriority: .mock
    )
}

extension SessionThread.Variant: @retroactive Mocked {
    public static var any: SessionThread.Variant = .contact
    public static var mock: SessionThread.Variant = .contact
}

extension Interaction.Variant: @retroactive Mocked {
    public static var any: Interaction.Variant = ._legacyStandardIncomingDeleted
    public static var mock: Interaction.Variant = .standardIncoming
}

extension Interaction: @retroactive Mocked {
    public static var any: Interaction = Interaction(
        id: .any,
        serverHash: .any,
        messageUuid: .any,
        threadId: .any,
        authorId: .any,
        variant: .any,
        body: .any,
        timestampMs: .any,
        receivedAtTimestampMs: .any,
        wasRead: .any,
        hasMention: .any,
        expiresInSeconds: .any,
        expiresStartedAtMs: .any,
        linkPreviewUrl: .any,
        openGroupServerMessageId: .any,
        openGroupWhisper: .any,
        openGroupWhisperMods: .any,
        openGroupWhisperTo: .any,
        state: .sent,
        recipientReadTimestampMs: .any,
        mostRecentFailureText: .any,
        isProMessage: .any
    )
    public static var mock: Interaction = Interaction(
        id: 123456,
        serverHash: .mock,
        messageUuid: nil,
        threadId: .mock,
        authorId: .mock,
        variant: .mock,
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
        isProMessage: false
    )
}

extension VisibleMessage: @retroactive Mocked {
    public static var any: VisibleMessage = VisibleMessage(text: .any)
    public static var mock: VisibleMessage = VisibleMessage(text: "mock")
}

extension KeychainStorage.DataKey: @retroactive Mocked {
    public static var any: KeychainStorage.DataKey = "__MOCKED_KEYCHAIN_DATE_KEY_VALUE__"
    public static var mock: KeychainStorage.DataKey = .dbCipherKeySpec
}

extension NotificationCategory: @retroactive Mocked {
    public static var any: NotificationCategory = .threadlessErrorMessage
    public static var mock: NotificationCategory = .incomingMessage
}

extension NotificationContent: @retroactive Mocked {
    public static var any: NotificationContent = NotificationContent(
        threadId: .any,
        threadVariant: .any,
        identifier: .any,
        category: .any,
        applicationState: .any
    )
    public static var mock: NotificationContent = NotificationContent(
        threadId: .mock,
        threadVariant: .mock,
        identifier: .mock,
        category: .mock,
        applicationState: .mock
    )
}

extension Preferences.NotificationSettings: @retroactive Mocked {
    public static var any: Preferences.NotificationSettings = Preferences.NotificationSettings(
        previewType: .any,
        sound: .any,
        mentionsOnly: .any,
        mutedUntil: .any
    )
    public static var mock: Preferences.NotificationSettings = Preferences.NotificationSettings(
        previewType: .mock,
        sound: .mock,
        mentionsOnly: .mock,
        mutedUntil: .mock
    )
}

extension ImageDataManager.DataSource: @retroactive Mocked {
    public static var any: ImageDataManager.DataSource = ImageDataManager.DataSource.data(.any, .any)
    public static var mock: ImageDataManager.DataSource = ImageDataManager.DataSource.data(.mock, .mock)
}

enum MockLibSessionConvertible: Int, Codable, LibSessionConvertibleEnum, Mocked {
    typealias LibSessionType = Int
    
    public static var any: MockLibSessionConvertible = .anyValue
    public static var mock: MockLibSessionConvertible = .mockValue
    
    case anyValue = 12345554321
    case mockValue = 0
    
    public static var defaultLibSessionValue: LibSessionType { 0 }
    public var libSessionValue: LibSessionType { 0 }
    
    public init(_ libSessionValue: LibSessionType) {
        self = .mockValue
    }
}

extension Preferences.Sound: @retroactive Mocked {
    public static var any: Preferences.Sound = .callFailure
    public static var mock: Preferences.Sound = .defaultNotificationSound
}

extension Preferences.NotificationPreviewType: @retroactive Mocked {
    public static var any: Preferences.NotificationPreviewType = .noNameNoPreview
    public static var mock: Preferences.NotificationPreviewType = .defaultPreviewType
}

extension Theme: @retroactive Mocked {
    public static var any: Theme = .classicLight
    public static var mock: Theme = .defaultTheme
}

extension Theme.PrimaryColor: @retroactive Mocked {
    public static var any: Theme.PrimaryColor = .yellow
    public static var mock: Theme.PrimaryColor = .defaultPrimaryColor
}

extension ConfigDump: @retroactive Mocked {
    public static var any: ConfigDump = ConfigDump(
        variant: .invalid,
        sessionId: .any,
        data: .any,
        timestampMs: .any
    )
    public static var mock: ConfigDump = ConfigDump(
        variant: .invalid,
        sessionId: .mock,
        data: .mock,
        timestampMs: .mock
    )
}

extension PollerDestination: @retroactive Mocked {
    public static var any: PollerDestination { .swarm(.any) }
    public static var mock: PollerDestination { .swarm(TestConstants.publicKey) }
}

extension CommunityPollerManagerSyncState: @retroactive Mocked {
    public static var any: CommunityPollerManagerSyncState = CommunityPollerManagerSyncState(
        serversBeingPolled: .any
    )
    
    public static var mock: CommunityPollerManagerSyncState = CommunityPollerManagerSyncState(
        serversBeingPolled: .mock
    )
}
