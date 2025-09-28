// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUIKit
import SessionUtilitiesKit
import TestUtilities

@testable import SessionMessagingKit

class MockLibSessionCache: LibSessionCacheType, Mockable {
    public var handler: MockHandler<LibSessionCacheType>
    
    required init(handler: MockHandler<LibSessionCacheType>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    var dependencies: Dependencies { handler.erasedDependencies as! Dependencies }
    var userSessionId: SessionId { handler.mock() }
    var isEmpty: Bool { handler.mock() }
    var allDumpSessionIds: Set<SessionId> { handler.mock() }
    
    // MARK: - State Management
    
    func loadState(_ db: ObservingDatabase, userEd25519SecretKey: [UInt8]) throws {
        try handler.mockThrowingNoReturn(args: [db, userEd25519SecretKey])
    }
    
    func loadDefaultStateFor(
        variant: ConfigDump.Variant,
        sessionId: SessionId,
        userEd25519SecretKey: [UInt8],
        groupEd25519SecretKey: [UInt8]?
    ) {
        handler.mockNoReturn(args: [variant, sessionId, userEd25519SecretKey, groupEd25519SecretKey])
    }
    
    func loadState(
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        userEd25519SecretKey: [UInt8],
        groupEd25519SecretKey: [UInt8]?,
        cachedData: Data?
    ) throws -> LibSession.Config {
        return try handler.mockThrowing(args: [variant, sessionId, userEd25519SecretKey, groupEd25519SecretKey, cachedData])
    }
    
    func hasConfig(for variant: ConfigDump.Variant, sessionId: SessionId) -> Bool {
        return handler.mock(args: [variant, sessionId])
    }
    
    func config(for variant: ConfigDump.Variant, sessionId: SessionId) -> LibSession.Config? {
        return handler.mock(args: [variant, sessionId])
    }
    
    func setConfig(for variant: ConfigDump.Variant, sessionId: SessionId, to config: LibSession.Config) {
        handler.mockNoReturn(args: [variant, sessionId, config])
    }
    
    func removeConfigs(for sessionId: SessionId) {
        handler.mockNoReturn(args: [sessionId])
    }
    
    func createDump(
        config: LibSession.Config?,
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        timestampMs: Int64
    ) throws -> ConfigDump? {
        return try handler.mockThrowing(args: [config, variant, sessionId, timestampMs])
    }
    
    // MARK: - Pushes
    
    func syncAllPendingPushes(_ db: ObservingDatabase) {
        handler.mockNoReturn(args: [db])
    }
    
    func withCustomBehaviour(_ behaviour: LibSession.CacheBehaviour, for sessionId: SessionId, variant: ConfigDump.Variant?, change: @escaping () throws -> ()) throws {
        try handler.mockThrowingNoReturn(args: [behaviour, sessionId, variant, change])
    }
    
    func performAndPushChange(
        _ db: ObservingDatabase,
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        change: @escaping (LibSession.Config?) throws -> ()
    ) throws {
        try handler.mockThrowingNoReturn(args: [db, variant, sessionId, change])
    }
    
    func perform(
        for variant: ConfigDump.Variant,
        sessionId: SessionId,
        change: @escaping (LibSession.Config?) throws -> ()
    ) throws -> LibSession.Mutation {
        return try handler.mockThrowing(args: [variant, sessionId, change])
    }
    
    func pendingPushes(swarmPublicKey: String) throws -> LibSession.PendingPushes {
        return handler.mock(args: [swarmPublicKey])
    }
    
    func createDumpMarkingAsPushed(
        data: [(pushData: LibSession.PendingPushes.PushData, hash: String?)],
        sentTimestamp: Int64,
        swarmPublicKey: String
    ) throws -> [ConfigDump] {
        return try handler.mockThrowing(args: [data, sentTimestamp, swarmPublicKey])
    }
    
    func addEvent(_ event: ObservedEvent) {
        handler.mockNoReturn(args: [event])
    }

    // MARK: - Config Message Handling
    
    func configNeedsDump(_ config: LibSession.Config?) -> Bool {
        return handler.mock(args: [config])
    }
    
    func activeHashes(for swarmPublicKey: String) -> [String] {
        return handler.mock(args: [swarmPublicKey])
    }
    
    func mergeConfigMessages(
        swarmPublicKey: String,
        messages: [ConfigMessageReceiveJob.Details.MessageInfo],
        afterMerge: (SessionId, ConfigDump.Variant, LibSession.Config?, Int64, [ObservableKey: Any]) throws -> ConfigDump?
    ) throws -> [LibSession.MergeResult] {
        try handler.mockThrowingNoReturn(args: [swarmPublicKey, messages])
        // TODO: Is this needed????
//        /// **Note:** Since `afterMerge` is non-escaping (and we don't want to change it to be so for the purposes of mocking
//        /// in unit test) we just call it directly instead of storing in `untrackedArgs`
//        let expectation: handler.MockFunction = getExpectation(args: [swarmPublicKey, messages])
//        handler.recordedCallInfo(for: {
//            $0.mergeConfigMessages(
//                swarmPublicKey: swarmPublicKey,
//                messages: messages,
//                afterMerge: { _, _, _, _, _ in })
//        })
//        
//        guard
//            expectation.closureCallArgs.count == 4,
//            let sessionId: SessionId = expectation.closureCallArgs[0] as? SessionId,
//            let variant: ConfigDump.Variant = expectation.closureCallArgs[1] as? ConfigDump.Variant,
//            let timestamp: Int64 = expectation.closureCallArgs[3] as? Int64,
//            let oldState: [ObservableKey: Any] = expectation.closureCallArgs[4] as? [ObservableKey: Any]
//        else {
//            return try handler.mockThrowing(args: [swarmPublicKey, messages])
//        }
//        
//        _ = try afterMerge(sessionId, variant, expectation.closureCallArgs[2] as? LibSession.Config, timestamp, oldState)
        return try handler.mockThrowing(args: [swarmPublicKey, messages])
    }
    
    func handleConfigMessages(
        _ db: ObservingDatabase,
        swarmPublicKey: String,
        messages: [ConfigMessageReceiveJob.Details.MessageInfo]
    ) throws {
        try handler.mockThrowingNoReturn(args: [db, swarmPublicKey, messages])
    }
    
    func unsafeDirectMergeConfigMessage(
        swarmPublicKey: String,
        messages: [ConfigMessageReceiveJob.Details.MessageInfo]
    ) throws {
        try handler.mockThrowingNoReturn(args: [swarmPublicKey, messages])
    }
    
    // MARK: - State Access
    
    var displayName: String? { handler.mock() }
    
    func has(_ key: Setting.BoolKey) -> Bool {
        return handler.mock(generics: [Bool.self], args: [key])
    }
    
    func has(_ key: Setting.EnumKey) -> Bool {
        return handler.mock(generics: [Setting.EnumKey.self], args: [key])
    }
    
    func get(_ key: Setting.BoolKey) -> Bool {
        return handler.mock(generics: [Bool.self], args: [key])
    }
    
    func get<T>(_ key: Setting.EnumKey) -> T? where T : LibSessionConvertibleEnum {
        return handler.mock(generics: [T.self], args: [key])
    }
    
    func set(_ key: Setting.BoolKey, _ value: Bool?) {
        handler.mockNoReturn(generics: [Bool.self], args: [key, value])
    }
    
    func set<T>(_ key: Setting.EnumKey, _ value: T?) where T : LibSessionConvertibleEnum {
        handler.mockNoReturn(generics: [T.self], args: [key, value])
    }
    
    func updateProfile(displayName: String, displayPictureUrl: String?, displayPictureEncryptionKey: Data?) throws {
        try handler.mockThrowingNoReturn(args: [displayName, displayPictureUrl, displayPictureEncryptionKey])
    }
    
    func canPerformChange(
        threadId: String,
        threadVariant: SessionThread.Variant,
        changeTimestampMs: Int64
    ) -> Bool {
        return handler.mock(args: [threadId, threadVariant, changeTimestampMs])
    }
    
    func conversationInConfig(
        threadId: String,
        threadVariant: SessionThread.Variant,
        visibleOnly: Bool,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> Bool {
        return handler.mock(args: [threadId, threadVariant, visibleOnly, openGroupUrlInfo])
    }
    
    func conversationDisplayName(
        threadId: String,
        threadVariant: SessionThread.Variant,
        contactProfile: Profile?,
        visibleMessage: VisibleMessage?,
        openGroupName: String?,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> String {
        return handler.mock(args: [threadId, threadVariant, contactProfile, visibleMessage, openGroupName, openGroupUrlInfo])
    }
    
    func conversationLastRead(
        threadId: String,
        threadVariant: SessionThread.Variant,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> Int64? {
        return handler.mock(args: [threadId, threadVariant, openGroupUrlInfo])
    }
    
    func isMessageRequest(
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> Bool {
        return handler.mock(args: [threadId, threadVariant])
    }
    
    func pinnedPriority(
        threadId: String,
        threadVariant: SessionThread.Variant,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> Int32 {
        return handler.mock(args: [threadId, threadVariant, openGroupUrlInfo])
    }
    
    func notificationSettings(
        threadId: String?,
        threadVariant: SessionThread.Variant,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> Preferences.NotificationSettings {
        return handler.mock(args: [threadId, threadVariant, openGroupUrlInfo])
    }
    
    func disappearingMessagesConfig(
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> DisappearingMessagesConfiguration? {
        return handler.mock(args: [threadId, threadVariant])
    }
    
    func isContactBlocked(contactId: String) -> Bool {
        return handler.mock(args: [contactId])
    }
    
    func isContactApproved(contactId: String) -> Bool {
        return handler.mock(args: [contactId])
    }
    
    func profile(
        contactId: String,
        threadId: String?,
        threadVariant: SessionThread.Variant?,
        visibleMessage: VisibleMessage?
    ) -> Profile? {
        return handler.mock(args: [contactId, threadId, threadVariant, visibleMessage])
    }
    
    func displayPictureUrl(threadId: String, threadVariant: SessionThread.Variant) -> String? {
        return handler.mock(args: [threadId, threadVariant])
    }
    
    func hasCredentials(groupSessionId: SessionId) -> Bool {
        return handler.mock(args: [groupSessionId])
    }
    
    func secretKey(groupSessionId: SessionId) -> [UInt8]? {
        return handler.mock(args: [groupSessionId])
    }
    
    func isAdmin(groupSessionId: SessionId) -> Bool {
        return handler.mock(args: [groupSessionId])
    }
    
    func loadAdminKey(
        groupIdentitySeed: Data,
        groupSessionId: SessionId
    ) throws {
        try handler.mockThrowingNoReturn(args: [groupIdentitySeed, groupSessionId])
    }
    
    func markAsInvited(groupSessionIds: [String]) throws {
        try handler.mockThrowingNoReturn(args: [groupSessionIds])
    }
    
    func markAsKicked(groupSessionIds: [String]) throws {
        try handler.mockThrowingNoReturn(args: [groupSessionIds])
    }
    
    func wasKickedFromGroup(groupSessionId: SessionId) -> Bool {
        return handler.mock(args: [groupSessionId])
    }
    
    func groupName(groupSessionId: SessionId) -> String? {
        return handler.mock(args: [groupSessionId])
    }
    
    func groupIsDestroyed(groupSessionId: SessionId) -> Bool {
        return handler.mock(args: [groupSessionId])
    }
    
    func groupDeleteBefore(groupSessionId: SessionId) -> TimeInterval? {
        return handler.mock(args: [groupSessionId])
    }
    
    func groupDeleteAttachmentsBefore(groupSessionId: SessionId) -> TimeInterval? {
        return handler.mock(args: [groupSessionId])
    }
    
    func authData(groupSessionId: SessionId) -> GroupAuthData {
        return handler.mock(args: [groupSessionId])
    }
}

// MARK: - Convenience

extension MockLibSessionCache {
    func defaultInitialSetup(configs: [ConfigDump.Variant: LibSession.Config?] = [:]) async throws {
        let userSessionId: SessionId = SessionId(.standard, hex: TestConstants.publicKey)
        
        for (key, value) in configs {
            switch value {
                case .none: break
                case .some(let config):
                    try await self
                        .when { $0.config(for: key, sessionId: .any) }
                        .thenReturn(config)
            }
        }
        
        try await self.when { $0.isEmpty }.thenReturn(false)
        try await self.when { $0.userSessionId }.thenReturn(userSessionId)
        try await self.when { $0.setConfig(for: .any, sessionId: .any, to: .any) }.thenReturn(())
        try await self.when { $0.removeConfigs(for: .any) }.thenReturn(())
        try await self.when { $0.hasConfig(for: .any, sessionId: .any) }.thenReturn(true)
        try await self
            .when {
                $0.loadDefaultStateFor(
                    variant: .any,
                    sessionId: .any,
                    userEd25519SecretKey: .any,
                    groupEd25519SecretKey: .any
                )
            }
            .thenReturn(())
        try await self
            .when { try $0.pendingPushes(swarmPublicKey: .any) }
            .thenReturn(LibSession.PendingPushes())
        try await self.when { $0.configNeedsDump(.any) }.thenReturn(false)
        try await self.when { $0.activeHashes(for: .any) }.thenReturn([])
        try await self
            .when { try $0.createDump(config: .any, for: .any, sessionId: .any, timestampMs: .any) }
            .thenReturn(nil)
        try await self
            .when { try $0.withCustomBehaviour(.any, for: .any, variant: .any, change: { }) }
            .then { args in
                let callback: (() throws -> Void)? = (args[test: 3] as? () throws -> Void)
                try? callback?()
            }
            .thenReturn(())
        try await self
            .when { try $0.performAndPushChange(.any, for: .any, sessionId: .any, change: { _ in }) }
            .then { args in
                let callback: ((LibSession.Config?) throws -> Void)? = (args[test: 3] as? (LibSession.Config?) throws -> Void)
                
                switch configs[(args[test: 1] as? ConfigDump.Variant ?? .invalid)] {
                    case .none: break
                    case .some(let config): try? callback?(config)
                }
            }
            .thenReturn(())
        try await self
            .when { try $0.perform(for: .any, sessionId: .any, change: { _ in }) }
            .then { args in
                let callback: ((LibSession.Config?) throws -> Void)? = (args[test: 2] as? (LibSession.Config?) throws -> Void)
                
                switch configs[(args[test: 0] as? ConfigDump.Variant ?? .invalid)] {
                    case .none: break
                    case .some(let config): try? callback?(config)
                }
            }
            .thenReturn(nil)
        try await self
            .when {
                try $0.createDumpMarkingAsPushed(
                    data: .any,
                    sentTimestamp: .any,
                    swarmPublicKey: .any
                )
            }
            .thenReturn([])
        try await self
            .when {
                $0.conversationInConfig(
                    threadId: .any,
                    threadVariant: .any,
                    visibleOnly: .any,
                    openGroupUrlInfo: .any
                )
            }
            .thenReturn(true)
        try await self
            .when {
                $0.conversationLastRead(
                    threadId: .any,
                    threadVariant: .any,
                    openGroupUrlInfo: .any
                )
            }
            .thenReturn(nil)
        try await self
            .when { $0.canPerformChange(threadId: .any, threadVariant: .any, changeTimestampMs: .any) }
            .thenReturn(true)
        try await self
            .when { $0.isMessageRequest(threadId: .any, threadVariant: .any) }
            .thenReturn(false)
        try await self
            .when { $0.pinnedPriority(threadId: .any, threadVariant: .any, openGroupUrlInfo: .any) }
            .thenReturn(LibSession.defaultNewThreadPriority)
        try await self
            .when { $0.disappearingMessagesConfig(threadId: .any, threadVariant: .any) }
            .thenReturn(nil)
        try await self.when { $0.isContactBlocked(contactId: .any) }.thenReturn(false)
        try await self
            .when { $0.profile(contactId: .any, threadId: .any, threadVariant: .any, visibleMessage: .any) }
            .thenReturn(Profile(id: "TestProfileId", name: "TestProfileName"))
        try await self.when { $0.hasCredentials(groupSessionId: .any) }.thenReturn(true)
        try await self.when { $0.secretKey(groupSessionId: .any) }.thenReturn(nil)
        try await self.when { $0.isAdmin(groupSessionId: .any) }.thenReturn(true)
        try await self.when { try $0.loadAdminKey(groupIdentitySeed: .any, groupSessionId: .any) }.thenReturn(())
        try await self.when { try $0.markAsKicked(groupSessionIds: .any) }.thenReturn(())
        try await self.when { try $0.markAsInvited(groupSessionIds: .any) }.thenReturn(())
        try await self.when { $0.wasKickedFromGroup(groupSessionId: .any) }.thenReturn(false)
        try await self.when { $0.groupName(groupSessionId: .any) }.thenReturn("TestGroupName")
        try await self.when { $0.groupIsDestroyed(groupSessionId: .any) }.thenReturn(false)
        try await self.when { $0.groupDeleteBefore(groupSessionId: .any) }.thenReturn(nil)
        try await self.when { $0.groupDeleteAttachmentsBefore(groupSessionId: .any) }.thenReturn(nil)
        try await self.when { $0.get(.any) }.thenReturn(false)
        try await self.when { $0.get(.any) }.thenReturn(MockLibSessionConvertible.any)
        try await self.when { $0.get(.any) }.thenReturn(Preferences.Sound.any)
        try await self.when { $0.get(.any) }.thenReturn(Preferences.NotificationPreviewType.any)
        try await self.when { $0.get(.any) }.thenReturn(Theme.any)
        try await self.when { $0.get(.any) }.thenReturn(Theme.PrimaryColor.any)
        try await self.when { $0.set(.any, true) }.thenReturn(())
        try await self.when { $0.set(.any, false) }.thenReturn(())
        try await self.when { $0.set(.defaultNotificationSound, Preferences.Sound.any) }.thenReturn(())
        try await self
            .when { $0.set(.preferencesNotificationPreviewType, Preferences.NotificationPreviewType.any) }
            .thenReturn(())
        try await self.when { $0.set(.theme, Theme.any) }.thenReturn(())
        try await self.when { $0.set(.themePrimaryColor, Theme.PrimaryColor.any) }.thenReturn(())
        try await self.when { $0.addEvent(.any) }.thenReturn(())
        try await self
            .when { $0.displayPictureUrl(threadId: .any, threadVariant: .any) }
            .thenReturn(nil)
        try await self
            .when { $0.authData(groupSessionId: .any) }
            .thenReturn(GroupAuthData(
                groupIdentityPrivateKey: Data([
                    1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8,
                    1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8,
                    1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8,
                    1, 2, 3, 4, 5, 6, 7, 8, 1, 2, 3, 4, 5, 6, 7, 8
                ]),
                authData: nil
            ))
    }
}
