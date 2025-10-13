// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUIKit
import SessionUtilitiesKit
import GRDB

@testable import SessionMessagingKit

class MockLibSessionCache: Mock<LibSessionCacheType>, LibSessionCacheType {
    var userSessionId: SessionId { mock() }
    var isEmpty: Bool { mock() }
    var allDumpSessionIds: Set<SessionId> { mock() }
    
    // MARK: - State Management
    
    func loadState(_ db: ObservingDatabase, requestId: String?) {
        mockNoReturn(args: [requestId], untrackedArgs: [db])
    }
    
    func loadDefaultStateFor(
        variant: ConfigDump.Variant,
        sessionId: SessionId,
        userEd25519SecretKey: [UInt8],
        groupEd25519SecretKey: [UInt8]?
    ) {
        mockNoReturn(args: [variant, sessionId, userEd25519SecretKey, groupEd25519SecretKey])
    }
    
    func loadState(
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        userEd25519SecretKey: [UInt8],
        groupEd25519SecretKey: [UInt8]?,
        cachedData: Data?
    ) throws -> LibSession.Config {
        return try mockThrowing(args: [variant, sessionId, userEd25519SecretKey, groupEd25519SecretKey, cachedData])
    }
    
    func hasConfig(for variant: ConfigDump.Variant, sessionId: SessionId) -> Bool {
        return mock(args: [variant, sessionId])
    }
    
    func config(for variant: ConfigDump.Variant, sessionId: SessionId) -> LibSession.Config? {
        return mock(args: [variant, sessionId])
    }
    
    func setConfig(for variant: ConfigDump.Variant, sessionId: SessionId, to config: LibSession.Config) {
        mockNoReturn(args: [variant, sessionId, config])
    }
    
    func removeConfigs(for sessionId: SessionId) {
        mockNoReturn(args: [sessionId])
    }
    
    func createDump(
        config: LibSession.Config?,
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        timestampMs: Int64
    ) throws -> ConfigDump? {
        return try mockThrowing(args: [config, variant, sessionId, timestampMs])
    }
    
    // MARK: - Pushes
    
    func syncAllPendingPushes(_ db: ObservingDatabase) {
        mockNoReturn(untrackedArgs: [db])
    }
    
    func withCustomBehaviour(_ behaviour: LibSession.CacheBehaviour, for sessionId: SessionId, variant: ConfigDump.Variant?, change: @escaping () throws -> ()) throws {
        try mockThrowingNoReturn(args: [behaviour, sessionId, variant], untrackedArgs: [change])
    }
    
    func performAndPushChange(
        _ db: ObservingDatabase,
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        change: @escaping (LibSession.Config?) throws -> ()
    ) throws {
        try mockThrowingNoReturn(args: [variant, sessionId], untrackedArgs: [db, change])
    }
    
    func perform(
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        change: @escaping (LibSession.Config?) throws -> ()
    ) throws -> LibSession.Mutation {
        return try mockThrowing(args: [variant, sessionId], untrackedArgs: [change])
    }
    
    func pendingPushes(swarmPublicKey: String) throws -> LibSession.PendingPushes {
        return mock(args: [swarmPublicKey])
    }
    
    func createDumpMarkingAsPushed(
        data: [(pushData: LibSession.PendingPushes.PushData, hash: String?)],
        sentTimestamp: Int64,
        swarmPublicKey: String
    ) throws -> [ConfigDump] {
        return try mockThrowing(args: [data, sentTimestamp, swarmPublicKey])
    }
    
    func addEvent(_ event: ObservedEvent) {
        mockNoReturn(args: [event])
    }

    // MARK: - Config Message Handling
    
    func configNeedsDump(_ config: LibSession.Config?) -> Bool {
        return mock(args: [config])
    }
    
    func activeHashes(for swarmPublicKey: String) -> [String] {
        return mock(args: [swarmPublicKey])
    }
    
    func mergeConfigMessages(
        swarmPublicKey: String,
        messages: [ConfigMessageReceiveJob.Details.MessageInfo],
        afterMerge: (SessionId, ConfigDump.Variant, LibSession.Config?, Int64, [ObservableKey: Any]) throws -> ConfigDump?
    ) throws -> [LibSession.MergeResult] {
        try mockThrowingNoReturn(args: [swarmPublicKey, messages])
        
        /// **Note:** Since `afterMerge` is non-escaping (and we don't want to change it to be so for the purposes of mocking
        /// in unit test) we just call it directly instead of storing in `untrackedArgs`
        let expectation: MockFunction = getExpectation(args: [swarmPublicKey, messages])
        
        guard
            expectation.closureCallArgs.count == 4,
            let sessionId: SessionId = expectation.closureCallArgs[0] as? SessionId,
            let variant: ConfigDump.Variant = expectation.closureCallArgs[1] as? ConfigDump.Variant,
            let timestamp: Int64 = expectation.closureCallArgs[3] as? Int64,
            let oldState: [ObservableKey: Any] = expectation.closureCallArgs[4] as? [ObservableKey: Any]
        else {
            return try mockThrowing(args: [swarmPublicKey, messages])
        }
        
        _ = try afterMerge(sessionId, variant, expectation.closureCallArgs[2] as? LibSession.Config, timestamp, oldState)
        return try mockThrowing(args: [swarmPublicKey, messages])
    }
    
    func handleConfigMessages(
        _ db: ObservingDatabase,
        swarmPublicKey: String,
        messages: [ConfigMessageReceiveJob.Details.MessageInfo]
    ) throws {
        try mockThrowingNoReturn(args: [swarmPublicKey, messages], untrackedArgs: [db])
    }
    
    func unsafeDirectMergeConfigMessage(
        swarmPublicKey: String,
        messages: [ConfigMessageReceiveJob.Details.MessageInfo]
    ) throws {
        try mockThrowingNoReturn(args: [swarmPublicKey, messages])
    }
    
    // MARK: - State Access
    
    var displayName: String? { mock() }
    
    func has(_ key: Setting.BoolKey) -> Bool {
        return mock(generics: [Bool.self], args: [key])
    }
    
    func has(_ key: Setting.EnumKey) -> Bool {
        return mock(generics: [Setting.EnumKey.self], args: [key])
    }
    
    func get(_ key: Setting.BoolKey) -> Bool {
        return mock(generics: [Bool.self], args: [key])
    }
    
    func get<T>(_ key: Setting.EnumKey) -> T? where T : LibSessionConvertibleEnum {
        return mock(generics: [T.self], args: [key])
    }
    
    func set(_ key: Setting.BoolKey, _ value: Bool?) {
        mockNoReturn(generics: [Bool.self], args: [key, value])
    }
    
    func set<T>(_ key: Setting.EnumKey, _ value: T?) where T : LibSessionConvertibleEnum {
        mockNoReturn(generics: [T.self], args: [key, value])
    }
    
    func updateProfile(displayName: String, displayPictureUrl: String?, displayPictureEncryptionKey: Data?, isReuploadProfilePicture: Bool) throws {
        try mockThrowingNoReturn(args: [displayName, displayPictureUrl, displayPictureEncryptionKey, isReuploadProfilePicture])
    }
    
    func canPerformChange(
        threadId: String,
        threadVariant: SessionThread.Variant,
        changeTimestampMs: Int64
    ) -> Bool {
        return mock(args: [threadId, threadVariant, changeTimestampMs])
    }
    
    func conversationInConfig(
        threadId: String,
        threadVariant: SessionThread.Variant,
        visibleOnly: Bool,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> Bool {
        return mock(args: [threadId, threadVariant, visibleOnly, openGroupUrlInfo])
    }
    
    func conversationDisplayName(
        threadId: String,
        threadVariant: SessionThread.Variant,
        contactProfile: Profile?,
        visibleMessage: VisibleMessage?,
        openGroupName: String?,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> String {
        return mock(args: [threadId, threadVariant, contactProfile, visibleMessage, openGroupName, openGroupUrlInfo])
    }
    
    func conversationLastRead(
        threadId: String,
        threadVariant: SessionThread.Variant,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> Int64? {
        return mock(args: [threadId, threadVariant, openGroupUrlInfo])
    }
    
    func isMessageRequest(
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> Bool {
        return mock(args: [threadId, threadVariant])
    }
    
    func pinnedPriority(
        threadId: String,
        threadVariant: SessionThread.Variant,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> Int32 {
        return mock(args: [threadId, threadVariant, openGroupUrlInfo])
    }
    
    func notificationSettings(
        threadId: String?,
        threadVariant: SessionThread.Variant,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> Preferences.NotificationSettings {
        return mock(args: [threadId, threadVariant, openGroupUrlInfo])
    }
    
    func disappearingMessagesConfig(
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> DisappearingMessagesConfiguration? {
        return mock(args: [threadId, threadVariant])
    }
    
    func isContactBlocked(contactId: String) -> Bool {
        return mock(args: [contactId])
    }
    
    func isContactApproved(contactId: String) -> Bool {
        return mock(args: [contactId])
    }
    
    func profile(
        contactId: String,
        threadId: String?,
        threadVariant: SessionThread.Variant?,
        visibleMessage: VisibleMessage?
    ) -> Profile? {
        return mock(args: [contactId, threadId, threadVariant, visibleMessage])
    }
    
    func displayPictureUrl(threadId: String, threadVariant: SessionThread.Variant) -> String? {
        return mock(args: [threadId, threadVariant])
    }
    
    func hasCredentials(groupSessionId: SessionId) -> Bool {
        return mock(args: [groupSessionId])
    }
    
    func secretKey(groupSessionId: SessionId) -> [UInt8]? {
        return mock(args: [groupSessionId])
    }
    
    func isAdmin(groupSessionId: SessionId) -> Bool {
        return mock(args: [groupSessionId])
    }
    
    func loadAdminKey(
        groupIdentitySeed: Data,
        groupSessionId: SessionId
    ) throws {
        try mockThrowingNoReturn(args: [groupIdentitySeed, groupSessionId])
    }
    
    func markAsInvited(groupSessionIds: [String]) throws {
        try mockThrowingNoReturn(args: [groupSessionIds])
    }
    
    func markAsKicked(groupSessionIds: [String]) throws {
        try mockThrowingNoReturn(args: [groupSessionIds])
    }
    
    func wasKickedFromGroup(groupSessionId: SessionId) -> Bool {
        return mock(args: [groupSessionId])
    }
    
    func groupName(groupSessionId: SessionId) -> String? {
        return mock(args: [groupSessionId])
    }
    
    func groupIsDestroyed(groupSessionId: SessionId) -> Bool {
        return mock(args: [groupSessionId])
    }
    
    func groupDeleteBefore(groupSessionId: SessionId) -> TimeInterval? {
        return mock(args: [groupSessionId])
    }
    
    func groupDeleteAttachmentsBefore(groupSessionId: SessionId) -> TimeInterval? {
        return mock(args: [groupSessionId])
    }
}

// MARK: - Convenience

extension Mock where T == LibSessionCacheType {
    func defaultInitialSetup(configs: [ConfigDump.Variant: LibSession.Config?] = [:]) {
        let userSessionId: SessionId = SessionId(.standard, hex: TestConstants.publicKey)
        
        configs.forEach { key, value in
            switch value {
                case .none: break
                case .some(let config): self.when { $0.config(for: key, sessionId: .any) }.thenReturn(config)
            }
        }
        
        self.when { $0.isEmpty }.thenReturn(false)
        self.when { $0.userSessionId }.thenReturn(userSessionId)
        self.when { $0.setConfig(for: .any, sessionId: .any, to: .any) }.thenReturn(())
        self.when { $0.removeConfigs(for: .any) }.thenReturn(())
        self.when { $0.hasConfig(for: .any, sessionId: .any) }.thenReturn(true)
        self
            .when {
                $0.loadDefaultStateFor(
                    variant: .any,
                    sessionId: .any,
                    userEd25519SecretKey: .any,
                    groupEd25519SecretKey: .any
                )
            }
            .thenReturn(())
        self
            .when { try $0.pendingPushes(swarmPublicKey: .any) }
            .thenReturn(LibSession.PendingPushes())
        self.when { $0.configNeedsDump(.any) }.thenReturn(false)
        self.when { $0.activeHashes(for: .any) }.thenReturn([])
        self
            .when { try $0.createDump(config: .any, for: .any, sessionId: .any, timestampMs: .any) }
            .thenReturn(nil)
        self
            .when { try $0.withCustomBehaviour(.any, for: .any, variant: .any, change: { }) }
            .then { args, untrackedArgs in
                let callback: (() throws -> Void)? = (untrackedArgs[test: 0] as? () throws -> Void)
                try? callback?()
            }
            .thenReturn(())
        self
            .when { try $0.performAndPushChange(.any, for: .any, sessionId: .any, change: { _ in }) }
            .then { args, untrackedArgs in
                let callback: ((LibSession.Config?) throws -> Void)? = (untrackedArgs[test: 1] as? (LibSession.Config?) throws -> Void)
                
                switch configs[(args[test: 0] as? ConfigDump.Variant ?? .invalid)] {
                    case .none: break
                    case .some(let config): try? callback?(config)
                }
            }
            .thenReturn(())
        self
            .when { try $0.perform(for: .any, sessionId: .any, change: { _ in }) }
            .then { args, untrackedArgs in
                let callback: ((LibSession.Config?) throws -> Void)? = (untrackedArgs[test: 0] as? (LibSession.Config?) throws -> Void)
                
                switch configs[(args[test: 0] as? ConfigDump.Variant ?? .invalid)] {
                    case .none: break
                    case .some(let config): try? callback?(config)
                }
            }
            .thenReturn(nil)
        self
            .when {
                try $0.createDumpMarkingAsPushed(
                    data: .any,
                    sentTimestamp: .any,
                    swarmPublicKey: .any
                )
            }
            .thenReturn([])
        self
            .when {
                $0.conversationInConfig(
                    threadId: .any,
                    threadVariant: .any,
                    visibleOnly: .any,
                    openGroupUrlInfo: .any
                )
            }
            .thenReturn(true)
        self
            .when {
                $0.conversationLastRead(
                    threadId: .any,
                    threadVariant: .any,
                    openGroupUrlInfo: .any
                )
            }
            .thenReturn(nil)
        self
            .when { $0.canPerformChange(threadId: .any, threadVariant: .any, changeTimestampMs: .any) }
            .thenReturn(true)
        self
            .when { $0.isMessageRequest(threadId: .any, threadVariant: .any) }
            .thenReturn(false)
        self
            .when { $0.pinnedPriority(threadId: .any, threadVariant: .any, openGroupUrlInfo: .any) }
            .thenReturn(LibSession.defaultNewThreadPriority)
        self
            .when { $0.disappearingMessagesConfig(threadId: .any, threadVariant: .any) }
            .thenReturn(nil)
        self.when { $0.isContactBlocked(contactId: .any) }.thenReturn(false)
        self
            .when { $0.profile(contactId: .any, threadId: .any, threadVariant: .any, visibleMessage: .any) }
            .thenReturn(Profile(id: "TestProfileId", name: "TestProfileName"))
        self.when { $0.hasCredentials(groupSessionId: .any) }.thenReturn(true)
        self.when { $0.secretKey(groupSessionId: .any) }.thenReturn(nil)
        self.when { $0.isAdmin(groupSessionId: .any) }.thenReturn(true)
        self.when { try $0.loadAdminKey(groupIdentitySeed: .any, groupSessionId: .any) }.thenReturn(())
        self.when { try $0.markAsKicked(groupSessionIds: .any) }.thenReturn(())
        self.when { try $0.markAsInvited(groupSessionIds: .any) }.thenReturn(())
        self.when { $0.wasKickedFromGroup(groupSessionId: .any) }.thenReturn(false)
        self.when { $0.groupName(groupSessionId: .any) }.thenReturn("TestGroupName")
        self.when { $0.groupIsDestroyed(groupSessionId: .any) }.thenReturn(false)
        self.when { $0.groupDeleteBefore(groupSessionId: .any) }.thenReturn(nil)
        self.when { $0.groupDeleteAttachmentsBefore(groupSessionId: .any) }.thenReturn(nil)
        self.when { $0.get(.any) }.thenReturn(false)
        self.when { $0.get(.any) }.thenReturn(MockLibSessionConvertible.mock)
        self.when { $0.get(.any) }.thenReturn(Preferences.Sound.defaultNotificationSound)
        self.when { $0.get(.any) }.thenReturn(Preferences.NotificationPreviewType.defaultPreviewType)
        self.when { $0.get(.any) }.thenReturn(Theme.defaultTheme)
        self.when { $0.get(.any) }.thenReturn(Theme.PrimaryColor.defaultPrimaryColor)
        self.when { $0.set(.any, true) }.thenReturn(())
        self.when { $0.set(.any, false) }.thenReturn(())
        self.when { $0.set(.defaultNotificationSound, Preferences.Sound.mock) }.thenReturn(())
        self.when { $0.set(.preferencesNotificationPreviewType, Preferences.NotificationPreviewType.mock) }.thenReturn(())
        self.when { $0.set(.theme, Theme.mock) }.thenReturn(())
        self.when { $0.set(.themePrimaryColor, Theme.PrimaryColor.mock) }.thenReturn(())
        self.when { $0.addEvent(.any) }.thenReturn(())
        self
            .when { $0.displayPictureUrl(threadId: .any, threadVariant: .any) }
            .thenReturn(nil)
    }
}
