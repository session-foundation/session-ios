// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUIKit
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

extension LibSession.OpenGroupUrlInfo: Mocked {
    static var mock: LibSession.OpenGroupUrlInfo = LibSession.OpenGroupUrlInfo(
        threadId: .mock,
        server: .mock,
        roomToken: .mock,
        publicKey: .mock
    )
}

extension ObservableKey: Mocked {
    static var mock: ObservableKey = "mockObservableKey"
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
        pinnedPriority: nil
    )
}

extension SessionThread.Variant: Mocked {
    static var mock: SessionThread.Variant = .contact
}

extension Interaction.Variant: Mocked {
    static var mock: Interaction.Variant = .standardIncoming
}

extension Interaction: Mocked {
    static var mock: Interaction = Interaction(
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
        mostRecentFailureText: nil
    )
}

extension VisibleMessage: Mocked {
    static var mock: VisibleMessage = VisibleMessage(text: "mock")
}

extension KeychainStorage.DataKey: Mocked {
    static var mock: KeychainStorage.DataKey = .dbCipherKeySpec
}

extension NotificationCategory: Mocked {
    static var mock: NotificationCategory = .incomingMessage
}

extension NotificationContent: Mocked {
    static var mock: NotificationContent = NotificationContent(
        threadId: .mock,
        threadVariant: .mock,
        identifier: .mock,
        category: .mock,
        applicationState: .any
    )
}

extension Preferences.NotificationSettings: Mocked {
    static var mock: Preferences.NotificationSettings = Preferences.NotificationSettings(
        previewType: .mock,
        sound: .mock,
        mentionsOnly: false,
        mutedUntil: nil
    )
}

extension ImageDataManager.DataSource: Mocked {
    static var mock: ImageDataManager.DataSource = ImageDataManager.DataSource.data("Id", Data([1, 2, 3]))
}

enum MockLibSessionConvertible: Int, Codable, LibSessionConvertibleEnum, Mocked {
    typealias LibSessionType = Int
    
    static var mock: MockLibSessionConvertible = .mockValue
    
    case mockValue = 0
    
    public static var defaultLibSessionValue: LibSessionType { 0 }
    public var libSessionValue: LibSessionType { 0 }
    
    public init(_ libSessionValue: LibSessionType) {
        self = .mockValue
    }
}

extension Preferences.Sound: Mocked {
    static var mock: Preferences.Sound = .defaultNotificationSound
}

extension Preferences.NotificationPreviewType: Mocked {
    static var mock: Preferences.NotificationPreviewType = .defaultPreviewType
}

extension Theme: Mocked {
    static var mock: Theme = .defaultTheme
}

extension Theme.PrimaryColor: Mocked {
    static var mock: Theme.PrimaryColor = .defaultPrimaryColor
}

extension ConfigDump: Mocked {
    static var mock: ConfigDump = ConfigDump(
        variant: .invalid,
        sessionId: "",
        data: Data(),
        timestampMs: 1234567890
    )
}
