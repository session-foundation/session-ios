// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import SessionUIKit
import SessionSnodeKit
import SessionUtil
import SessionUtilitiesKit

// MARK: - Convenience

public extension LibSession {
    enum Crypto {
        public typealias Domain = String
    }
    
    /// The default priority for newly created threads - the default value is for threads to be hidden as we explicitly make threads visible
    /// when sending or receiving messages
    static var defaultNewThreadPriority: Int32 { return hiddenPriority }

    /// A `0` `priority` value indicates visible, but not pinned
    static let visiblePriority: Int32 = 0
    
    /// A negative `priority` value indicates hidden
    static let hiddenPriority: Int32 = -1
}

internal extension LibSession {
    /// This is a buffer period within which we will process messages which would result in a config change, any message which would normally
    /// result in a config change which was sent before `lastConfigMessage.timestamp - configChangeBufferPeriodMs` will not
    /// actually have it's changes applied (info messages would still be inserted though)
    static let configChangeBufferPeriodMs: Int64 = ((2 * 60) * 1000)
    
    static let columnsRelatedToThreads: [ColumnExpression] = [
        SessionThread.Columns.pinnedPriority,
        SessionThread.Columns.shouldBeVisible
    ]
    
    static func assignmentsRequireConfigUpdate(_ assignments: [ConfigColumnAssignment]) -> Bool {
        let targetColumns: Set<ColumnKey> = Set(assignments.map { ColumnKey($0.column) })
        let allColumnsThatTriggerConfigUpdate: Set<ColumnKey> = []
            .appending(contentsOf: columnsRelatedToUserProfile)
            .appending(contentsOf: columnsRelatedToContacts)
            .appending(contentsOf: columnsRelatedToConvoInfoVolatile)
            .appending(contentsOf: columnsRelatedToUserGroups)
            .appending(contentsOf: columnsRelatedToThreads)
            .appending(contentsOf: columnsRelatedToGroupInfo)
            .appending(contentsOf: columnsRelatedToGroupMembers)
            .appending(contentsOf: columnsRelatedToGroupKeys)
            .map { ColumnKey($0) }
            .asSet()
        
        return !allColumnsThatTriggerConfigUpdate.isDisjoint(with: targetColumns)
    }
    
    static func shouldBeVisible(priority: Int32) -> Bool {
        return (priority >= LibSession.visiblePriority)
    }
    
    @discardableResult static func updatingThreads<T>(
        _ db: Database,
        _ updated: [T],
        using dependencies: Dependencies
    ) throws -> [T] {
        guard let updatedThreads: [SessionThread] = updated as? [SessionThread] else {
            throw StorageError.generic
        }
        
        // If we have no updated threads then no need to continue
        guard !updatedThreads.isEmpty else { return updated }
        
        // Exclude any "draft" conversations from updating `libSession` (we don't want them to be
        // synced until they turn into "real" conversations)
        let targetThreads: [SessionThread] = updatedThreads.filter {
            $0.isDraft != true
        }
        
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let groupedThreads: [SessionThread.Variant: [SessionThread]] = targetThreads
            .grouped(by: \.variant)
        let urlInfo: [String: OpenGroupUrlInfo] = try OpenGroupUrlInfo
            .fetchAll(db, ids: targetThreads.map { $0.id })
            .reduce(into: [:]) { result, next in result[next.threadId] = next }
        
        // Update the unread state for the threads first (just in case that's what changed)
        try LibSession.updateMarkedAsUnreadState(db, threads: targetThreads, using: dependencies)
        
        // Then update the `hidden` and `priority` values
        try groupedThreads.forEach { variant, threads in
            switch variant {
                case .contact:
                    // If the 'Note to Self' conversation is pinned then we need to custom handle it
                    // first as it's part of the UserProfile config
                    if let noteToSelf: SessionThread = threads.first(where: { $0.id == userSessionId.hexString }) {
                        try dependencies.mutate(cache: .libSession) { cache in
                            try cache.performAndPushChange(db, for: .userProfile, sessionId: userSessionId) { config in
                                try LibSession.updateNoteToSelf(
                                    priority: {
                                        guard noteToSelf.shouldBeVisible else { return LibSession.hiddenPriority }
                                        
                                        return noteToSelf.pinnedPriority
                                            .map { Int32($0 == 0 ? LibSession.visiblePriority : max($0, 1)) }
                                            .defaulting(to: LibSession.visiblePriority)
                                    }(),
                                    in: config
                                )
                            }
                        }
                    }
                    
                    // Remove the 'Note to Self' convo from the list for updating contact priorities
                    let remainingThreads: [SessionThread] = threads.filter { $0.id != userSessionId.hexString }
                    
                    guard !remainingThreads.isEmpty else { return }
                    
                    try dependencies.mutate(cache: .libSession) { cache in
                        try cache.performAndPushChange(db, for: .contacts, sessionId: userSessionId) { config in
                            try LibSession.upsert(
                                contactData: remainingThreads
                                    .map { thread in
                                        SyncedContactInfo(
                                            id: thread.id,
                                            priority: {
                                                guard thread.shouldBeVisible else { return LibSession.hiddenPriority }
                                                
                                                return thread.pinnedPriority
                                                    .map { Int32($0 == 0 ? LibSession.visiblePriority : max($0, 1)) }
                                                    .defaulting(to: LibSession.visiblePriority)
                                            }()
                                        )
                                    },
                                in: config,
                                using: dependencies
                            )
                        }
                    }
                    
                case .community:
                    try dependencies.mutate(cache: .libSession) { cache in
                        try cache.performAndPushChange(db, for: .userGroups, sessionId: userSessionId) { config in
                            try LibSession.upsert(
                                communities: threads
                                    .compactMap { thread -> CommunityInfo? in
                                        urlInfo[thread.id].map { urlInfo in
                                            CommunityInfo(
                                                urlInfo: urlInfo,
                                                priority: thread.pinnedPriority
                                                    .map { Int32($0 == 0 ? LibSession.visiblePriority : max($0, 1)) }
                                                    .defaulting(to: LibSession.visiblePriority)
                                            )
                                        }
                                    },
                                in: config
                            )
                        }
                    }
                    
                case .legacyGroup:
                    try dependencies.mutate(cache: .libSession) { cache in
                        try cache.performAndPushChange(db, for: .userGroups, sessionId: userSessionId) { config in
                            try LibSession.upsert(
                                legacyGroups: threads
                                    .map { thread in
                                        LegacyGroupInfo(
                                            id: thread.id,
                                            priority: thread.pinnedPriority
                                                .map { Int32($0 == 0 ? LibSession.visiblePriority : max($0, 1)) }
                                                .defaulting(to: LibSession.visiblePriority)
                                        )
                                    },
                                in: config
                            )
                        }
                    }
                
                case .group:
                    try dependencies.mutate(cache: .libSession) { cache in
                        try cache.performAndPushChange(db, for: .userGroups, sessionId: userSessionId) { config in
                            try LibSession.upsert(
                                groups: threads
                                    .map { thread in
                                        GroupUpdateInfo(
                                            groupSessionId: thread.id,
                                            priority: thread.pinnedPriority
                                                .map { Int32($0 == 0 ? LibSession.visiblePriority : max($0, 1)) }
                                                .defaulting(to: LibSession.visiblePriority)
                                        )
                                    },
                                in: config,
                                using: dependencies
                            )
                        }
                    }
            }
        }
        
        return updated
    }
    
    static func hasSetting(
        _ db: Database,
        forKey key: String,
        using dependencies: Dependencies
    ) throws -> Bool {
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        
        // Currently the only synced setting is 'checkForCommunityMessageRequests'
        switch key {
            case Setting.BoolKey.checkForCommunityMessageRequests.rawValue:
                return dependencies.mutate(cache: .libSession) { cache in
                    let config: LibSession.Config? = cache.config(for: .userProfile, sessionId: userSessionId)
                    
                    return (((try? LibSession.rawBlindedMessageRequestValue(in: config)) ?? 0) >= 0)
                }
                
            default: return false
        }
    }
    
    static func updatingSetting(
        _ db: Database,
        _ updated: Setting?,
        using dependencies: Dependencies
    ) throws {
        // Don't current support any nullable settings
        guard let updatedSetting: Setting = updated else { return }
        
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        
        // Currently the only synced setting is 'checkForCommunityMessageRequests'
        switch updatedSetting.id {
            case Setting.BoolKey.checkForCommunityMessageRequests.rawValue:
                try dependencies.mutate(cache: .libSession) { cache in
                    try cache.performAndPushChange(db, for: .userProfile, sessionId: userSessionId) { config in
                        try LibSession.updateSettings(
                            checkForCommunityMessageRequests: updatedSetting.unsafeValue(as: Bool.self),
                            in: config
                        )
                    }
                }
                
            default: break
        }
    }
    
    static func kickFromConversationUIIfNeeded(removedThreadIds: [String], using dependencies: Dependencies) {
        guard !removedThreadIds.isEmpty else { return }
        
        // If the user is currently navigating somewhere within the view hierarchy of a conversation
        // we just deleted then return to the home screen
        DispatchQueue.main.async {
            guard
                let rootViewController: UIViewController = dependencies[singleton: .appContext].mainWindow?.rootViewController,
                let topBannerController: TopBannerController = (rootViewController as? TopBannerController),
                !topBannerController.children.isEmpty,
                let navController: UINavigationController = topBannerController.children[0] as? UINavigationController
            else { return }
            
            // Extract the ones which will respond to LibSession changes
            let targetViewControllers: [any LibSessionRespondingViewController] = navController
                .viewControllers
                .compactMap { $0 as? LibSessionRespondingViewController }
            let presentedNavController: UINavigationController? = (navController.presentedViewController as? UINavigationController)
            let presentedTargetViewControllers: [any LibSessionRespondingViewController] = (presentedNavController?
                .viewControllers
                .compactMap { $0 as? LibSessionRespondingViewController })
                .defaulting(to: [])
            
            // Make sure we have a conversation list and that one of the removed conversations are
            // in the nav hierarchy
            let rootNavControllerNeedsPop: Bool = (
                targetViewControllers.count > 1 &&
                targetViewControllers.contains(where: { $0.isConversationList }) &&
                targetViewControllers.contains(where: { $0.isConversation(in: removedThreadIds) })
            )
            let presentedNavControllerNeedsPop: Bool = (
                presentedTargetViewControllers.count > 1 &&
                presentedTargetViewControllers.contains(where: { $0.isConversationList }) &&
                presentedTargetViewControllers.contains(where: { $0.isConversation(in: removedThreadIds) })
            )
            
            // Force the UI to refresh if needed (most screens should do this automatically via database
            // observation, but a couple of screens don't so need to be done manually)
            targetViewControllers
                .appending(contentsOf: presentedTargetViewControllers)
                .filter { $0.isConversationList }
                .forEach { $0.forceRefreshIfNeeded() }
            
            switch (rootNavControllerNeedsPop, presentedNavControllerNeedsPop) {
                case (true, false):
                    // Return to the conversation list as the removed conversation will be invalid
                    guard
                        let targetViewController: UIViewController = navController.viewControllers
                            .last(where: { viewController in
                                ((viewController as? LibSessionRespondingViewController)?.isConversationList)
                                    .defaulting(to: false)
                            })
                    else { return }
                    
                    if navController.presentedViewController != nil {
                        navController.dismiss(animated: false) {
                            navController.popToViewController(targetViewController, animated: true)
                        }
                    }
                    else {
                        navController.popToViewController(targetViewController, animated: true)
                    }
                    
                case (false, true):
                    // Return to the conversation list as the removed conversation will be invalid
                    guard
                        let targetViewController: UIViewController = presentedNavController?
                            .viewControllers
                            .last(where: { viewController in
                                ((viewController as? LibSessionRespondingViewController)?.isConversationList)
                                    .defaulting(to: false)
                            })
                    else { return }
                    
                    if presentedNavController?.presentedViewController != nil {
                        presentedNavController?.dismiss(animated: false) {
                            presentedNavController?.popToViewController(targetViewController, animated: true)
                        }
                    }
                    else {
                        presentedNavController?.popToViewController(targetViewController, animated: true)
                    }
                    
                default: break
            }
        }
    }
    
    static func checkLoopLimitReached(_ loopCounter: inout Int, for variant: ConfigDump.Variant, maxLoopCount: Int = 50000) throws {
        loopCounter += 1
        
        guard loopCounter < maxLoopCount else {
            Log.critical(.libSession, "Got stuck in infinite loop processing '\(variant)' data")
            throw LibSessionError.processingLoopLimitReached
        }
    }
}

// MARK: - State Access

public extension LibSession.Config {
    func canPerformChange(
        sessionId: SessionId,
        changeTimestampMs: Int64,
        using dependencies: Dependencies
    ) -> Bool {
        let configDumpTimestamp: TimeInterval = dependencies[singleton: .extensionHelper]
            .lastUpdatedTimestamp(for: sessionId, variant: variant)
        let configDumpTimestampMs: Int64 = Int64(configDumpTimestamp * 1000)
        
        /// Ensure the change occurred after the last config message was handled (minus the buffer period)
        return (changeTimestampMs >= (configDumpTimestampMs - LibSession.configChangeBufferPeriodMs))
    }
    
    func pinnedPriority(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> Int32? {
        guard var cThreadId: [CChar] = threadId.cString(using: .utf8) else {
            return LibSession.defaultNewThreadPriority
        }
        
        switch (threadVariant, self) {
            case (_, .userProfile(let conf)): return user_profile_get_nts_priority(conf)
                
            case (_, .contacts(let conf)):
                var contact: contacts_contact = contacts_contact()
                
                guard contacts_get(conf, &contact, &cThreadId) else {
                    LibSessionError.clear(conf)
                    return LibSession.defaultNewThreadPriority
                }
                
                return contact.priority
                
            case (.community, .userGroups(let conf)):
                guard
                    let urlInfo: LibSession.OpenGroupUrlInfo = try? LibSession.OpenGroupUrlInfo
                        .fetchOne(db, id: threadId),
                    var cBaseUrl: [CChar] = urlInfo.server.cString(using: .utf8),
                    var cRoom: [CChar] = urlInfo.roomToken.cString(using: .utf8)
                else { return LibSession.defaultNewThreadPriority }
                
                var community: ugroups_community_info = ugroups_community_info()
                _ = user_groups_get_community(conf, &community, &cBaseUrl, &cRoom)
                LibSessionError.clear(conf)
                
                return community.priority
            
            case (.legacyGroup, .userGroups(let conf)):
                let groupInfo: UnsafeMutablePointer<ugroups_legacy_group_info>? = user_groups_get_legacy_group(conf, &cThreadId)
                LibSessionError.clear(conf)
                
                defer {
                    if groupInfo != nil {
                        ugroups_legacy_group_free(groupInfo)
                    }
                }
                
                return (groupInfo?.pointee.priority ?? LibSession.defaultNewThreadPriority)
                
            case (.group, .userGroups(let conf)):
                var group: ugroups_group_info = ugroups_group_info()
                _ = user_groups_get_group(conf, &group, &cThreadId)
                LibSessionError.clear(conf)
                
                return group.priority
            
            default:
                Log.warn(.libSession, "Attempted to retrieve priority for invalid combination of threadVariant: \(threadVariant) and config variant: \(variant)")
                return LibSession.defaultNewThreadPriority
        }
    }
    
    /// Returns whether the specified conversation is a message request
    ///
    /// **Note:** Defaults to `true` on failure
    func isMessageRequest(
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> Bool {
        guard var cThreadId: [CChar] = threadId.cString(using: .utf8) else { return true }
        
        switch (threadVariant, self) {
            case (.community, _), (.legacyGroup, _): return false
            case (_, .contacts(let conf)):
                var contact: contacts_contact = contacts_contact()
                
                guard contacts_get(conf, &contact, &cThreadId) else {
                    LibSessionError.clear(conf)
                    return true
                }
                
                return contact.approved
                
            case (.group, .userGroups(let conf)):
                var group: ugroups_group_info = ugroups_group_info()
                _ = user_groups_get_group(conf, &group, &cThreadId)
                LibSessionError.clear(conf)
                
                return (group.invited == false)
            
            default:
                Log.warn(.libSession, "Attempted to determine if a conversation was a message request for invalid combination of threadVariant: \(threadVariant) and config variant: \(variant)")
                return true
        }
    }
    
    func notificationSettings(
        threadId: String,
        threadVariant: SessionThread.Variant,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?,
        applicationState: UIApplication.State
    ) -> Preferences.NotificationSettings {
        guard var cThreadId: [CChar] = threadId.cString(using: .utf8) else {
            return .defaultFor(threadVariant)
        }
        
        // TODO: [Database Relocation] Need to add this to local libSession
//        sound = (db[.defaultNotificationSound] ?? Preferences.Sound.defaultNotificationSound)
        let sound: UNNotificationSound? = Preferences.Sound.defaultNotificationSound
            .notificationSound(isQuiet: (applicationState == .active))
        
        // TODO: [Database Relocation] Need to add this to local libSession
//        let previewType: Preferences.NotificationPreviewType = db[.preferencesNotificationPreviewType]
//            .defaulting(to: .defaultPreviewType)
        
        switch (threadVariant, self) {
            case (_, .contacts(let conf)):
                var contact: contacts_contact = contacts_contact()
                
                guard contacts_get(conf, &contact, &cThreadId) else {
                    LibSessionError.clear(conf)
                    return .defaultFor(threadVariant)
                }
                
                return Preferences.NotificationSettings(
                    mode: Preferences.NotificationMode(
                        libSessionValue: contact.notifications,
                        threadVariant: threadVariant
                    ),
                    previewType: .defaultPreviewType,    // TODO: [Database Relocation] Add this
                    sound: sound,
                    mutedUntil: (contact.mute_until > 0 ? TimeInterval(contact.mute_until) : nil)
                )
                
            case (.legacyGroup, _): return .defaultFor(threadVariant)
            case (.community, .userGroups(let conf)):
                guard
                    let urlInfo: LibSession.OpenGroupUrlInfo = openGroupUrlInfo,
                    var cBaseUrl: [CChar] = urlInfo.server.cString(using: .utf8),
                    var cRoom: [CChar] = urlInfo.roomToken.cString(using: .utf8)
                else { return .defaultFor(threadVariant) }
                
                var community: ugroups_community_info = ugroups_community_info()
                _ = user_groups_get_community(conf, &community, &cBaseUrl, &cRoom)
                LibSessionError.clear(conf)
                
                return Preferences.NotificationSettings(
                    mode: Preferences.NotificationMode(
                        libSessionValue: community.notifications,
                        threadVariant: threadVariant
                    ),
                    previewType: .defaultPreviewType,    // TODO: [Database Relocation] Add this
                    sound: sound,
                    mutedUntil: (community.mute_until > 0 ? TimeInterval(community.mute_until) : nil)
                )
                
            case (.group, .userGroups(let conf)):
                var group: ugroups_group_info = ugroups_group_info()
                _ = user_groups_get_group(conf, &group, &cThreadId)
                LibSessionError.clear(conf)
                
                return Preferences.NotificationSettings(
                    mode: Preferences.NotificationMode(
                        libSessionValue: group.notifications,
                        threadVariant: threadVariant
                    ),
                    previewType: .defaultPreviewType,    // TODO: [Database Relocation] Add this
                    sound: sound,
                    mutedUntil: (group.mute_until > 0 ? TimeInterval(group.mute_until) : nil)
                )
            
            default:
                Log.warn(.libSession, "Attempted to retrieve notification settings for invalid combination of threadVariant: \(threadVariant) and config variant: \(variant)")
                return .defaultFor(threadVariant)
        }
    }
    
    func disappearingMessagesConfig(
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> DisappearingMessagesConfiguration? {
        guard var cThreadId: [CChar] = threadId.cString(using: .utf8) else { return nil }
        
        switch (threadVariant, self) {
            case (.community, _): return nil
            case (_, .userProfile(let conf)):
                let targetExpiry: Int32 = user_profile_get_nts_expiry(conf)
                let targetIsEnabled: Bool = (targetExpiry > 0)
                
                return DisappearingMessagesConfiguration(
                    threadId: threadId,
                    isEnabled: targetIsEnabled,
                    durationSeconds: TimeInterval(targetExpiry),
                    type: targetIsEnabled ? .disappearAfterSend : .unknown
                )
                
            case (_, .contacts(let conf)):
                var contact: contacts_contact = contacts_contact()
                
                guard contacts_get(conf, &contact, &cThreadId) else {
                    LibSessionError.clear(conf)
                    return nil
                }
                
                return DisappearingMessagesConfiguration(
                    threadId: threadId,
                    isEnabled: contact.exp_seconds > 0,
                    durationSeconds: TimeInterval(contact.exp_seconds),
                    type: DisappearingMessagesConfiguration.DisappearingMessageType(
                        libSessionType: contact.exp_mode
                    )
                )
                
            case (.legacyGroup, .userGroups(let conf)):
                let groupInfo: UnsafeMutablePointer<ugroups_legacy_group_info>? = user_groups_get_legacy_group(conf, &cThreadId)
                LibSessionError.clear(conf)
                
                defer {
                    if groupInfo != nil {
                        ugroups_legacy_group_free(groupInfo)
                    }
                }
                
                return groupInfo.map { info in
                    DisappearingMessagesConfiguration(
                        threadId: threadId,
                        isEnabled: (info.pointee.disappearing_timer > 0),
                        durationSeconds: TimeInterval(info.pointee.disappearing_timer),
                        type: .disappearAfterSend
                    )
                }
                
            case (.group, .groupInfo(let conf)):
                let durationSeconds: Int32 = groups_info_get_expiry_timer(conf)
                
                return DisappearingMessagesConfiguration(
                    threadId: threadId,
                    isEnabled: (durationSeconds > 0),
                    durationSeconds: TimeInterval(durationSeconds),
                    type: .disappearAfterSend
                )
            
            default:
                Log.warn(.libSession, "Attempted to retrieve disappearing messages config for invalid combination of threadVariant: \(threadVariant) and config variant: \(variant)")
                return nil
        }
    }
    
    func isAdmin() -> Bool {
        guard case .groupKeys(let conf, _, _) = self else { return false }
        
        return groups_keys_is_admin(conf)
    }
    
    func conversationInConfig(
        threadId: String,
        threadVariant: SessionThread.Variant,
        visibleOnly: Bool,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?,
        using dependencies: Dependencies
    ) -> Bool {
        // Currently blinded conversations cannot be contained in the config, so there is no
        // point checking (it'll always be false)
        guard
            threadVariant == .community || (
                (try? SessionId(from: threadId))?.prefix != .blinded15 &&
                (try? SessionId(from: threadId))?.prefix != .blinded25
            ),
            var cThreadId: [CChar] = threadId.cString(using: .utf8)
        else { return false }
        
        switch (threadVariant, self) {
            case (_, .userProfile(let conf)):
                return (
                    !visibleOnly ||
                    LibSession.shouldBeVisible(priority: user_profile_get_nts_priority(conf))
                )
            
            case (_, .contacts(let conf)):
                var contact: contacts_contact = contacts_contact()
                
                guard contacts_get(conf, &contact, &cThreadId) else {
                    LibSessionError.clear(conf)
                    return false
                }
                
                /// If the user opens a conversation with an existing contact but doesn't send them a message
                /// then the one-to-one conversation should remain hidden so we want to delete the `SessionThread`
                /// when leaving the conversation
                return (!visibleOnly || LibSession.shouldBeVisible(priority: contact.priority))
                
            case (.community, .userGroups(let conf)):
                guard
                    let urlInfo: LibSession.OpenGroupUrlInfo = openGroupUrlInfo,
                    var cBaseUrl: [CChar] = urlInfo.server.cString(using: .utf8),
                    var cRoom: [CChar] = urlInfo.roomToken.cString(using: .utf8)
                else { return false }
                
                var community: ugroups_community_info = ugroups_community_info()
                
                /// Not handling the `hidden` behaviour for communities so just indicate the existence
                let result: Bool = user_groups_get_community(conf, &community, &cBaseUrl, &cRoom)
                LibSessionError.clear(conf)
                
                return result
                
            case (.legacyGroup, .userGroups(let conf)):
                let groupInfo: UnsafeMutablePointer<ugroups_legacy_group_info>? = user_groups_get_legacy_group(conf, &cThreadId)
                LibSessionError.clear(conf)
                
                /// Not handling the `hidden` behaviour for legacy groups so just indicate the existence
                if groupInfo != nil {
                    ugroups_legacy_group_free(groupInfo)
                    return true
                }
                
                return false
                
            case (.group, .userGroups(let conf)):
                var group: ugroups_group_info = ugroups_group_info()
                
                /// Not handling the `hidden` behaviour for legacy groups so just indicate the existence
                return user_groups_get_group(conf, &group, &cThreadId)
            
            default: return false
        }
    }
}

// MARK: - Dependencies Convenience

public extension Dependencies {
    @discardableResult func mutate<R>(
        cache: CacheConfig<LibSessionCacheType, LibSessionImmutableCacheType>,
        config variant: ConfigDump.Variant,
        _ mutation: (LibSession.Config?) -> R
    ) -> R {
        let userSessionId: SessionId = self[cache: .general].sessionId
        
        return mutate(cache: cache) { cache in
            mutation(cache.config(for: variant, sessionId: userSessionId))
        }
    }
    
    @discardableResult func mutate<R>(
        cache: CacheConfig<LibSessionCacheType, LibSessionImmutableCacheType>,
        config variant: ConfigDump.Variant,
        groupSessionId: SessionId,
        _ mutation: (LibSession.Config?) -> R
    ) -> R {
        return mutate(cache: cache) { cache in
            mutation(cache.config(for: variant, sessionId: groupSessionId))
        }
    }
    
    @discardableResult func mutate<R>(
        cache: CacheConfig<LibSessionCacheType, LibSessionImmutableCacheType>,
        config variant: ConfigDump.Variant,
        _ mutation: (LibSession.Config?) throws -> R
    ) throws -> R {
        let userSessionId: SessionId = self[cache: .general].sessionId
        
        return try mutate(cache: cache) { cache in
            try mutation(cache.config(for: variant, sessionId: userSessionId))
        }
    }
    
    @discardableResult func mutate<R>(
        cache: CacheConfig<LibSessionCacheType, LibSessionImmutableCacheType>,
        config variant: ConfigDump.Variant,
        groupSessionId: SessionId,
        _ mutation: (LibSession.Config?) throws -> R
    ) throws -> R {
        return try mutate(cache: cache) { cache in
            try mutation(cache.config(for: variant, sessionId: groupSessionId))
        }
    }
}

// MARK: - ColumnKey

internal extension LibSession {
    struct ColumnKey: Equatable, Hashable {
        let sourceType: Any.Type
        let columnName: String
        
        init(_ column: ColumnExpression) {
            self.sourceType = type(of: column)
            self.columnName = column.name
        }
        
        func hash(into hasher: inout Hasher) {
            ObjectIdentifier(sourceType).hash(into: &hasher)
            columnName.hash(into: &hasher)
        }
        
        static func == (lhs: ColumnKey, rhs: ColumnKey) -> Bool {
            return (
                lhs.sourceType == rhs.sourceType &&
                lhs.columnName == rhs.columnName
            )
        }
    }
}

// MARK: - PriorityVisibilityInfo

extension LibSession {
    struct PriorityVisibilityInfo: Codable, FetchableRecord, Identifiable {
        let id: String
        let variant: SessionThread.Variant
        let pinnedPriority: Int32?
        let shouldBeVisible: Bool
    }
}

// MARK: - OpenGroupInfo

public extension LibSession {
    struct OpenGroupUrlInfo: FetchableRecord, Codable, Hashable {
        let threadId: String
        let server: String
        let roomToken: String
        let publicKey: String
        
        // MARK: - Queries
        
        static func fetchOne(_ db: Database, id: String) throws -> OpenGroupUrlInfo? {
            return try OpenGroup
                .filter(id: id)
                .select(.threadId, .server, .roomToken, .publicKey)
                .asRequest(of: OpenGroupUrlInfo.self)
                .fetchOne(db)
        }
        
        static func fetchAll(_ db: Database, ids: [String]) throws -> [OpenGroupUrlInfo] {
            return try OpenGroup
                .filter(ids: ids)
                .select(.threadId, .server, .roomToken, .publicKey)
                .asRequest(of: OpenGroupUrlInfo.self)
                .fetchAll(db)
        }
    }
    
    struct OpenGroupCapabilityInfo: FetchableRecord, Codable, Hashable {
        private let urlInfo: OpenGroupUrlInfo
        
        var threadId: String { urlInfo.threadId }
        var server: String { urlInfo.server }
        var roomToken: String { urlInfo.roomToken }
        var publicKey: String { urlInfo.publicKey }
        let capabilities: Set<Capability.Variant>
        
        // MARK: - Queries
        
        public static func fetchOne(_ db: Database, id: String) throws -> OpenGroupCapabilityInfo? {
            let maybeUrlInfo: OpenGroupUrlInfo? = try OpenGroup
                .filter(id: id)
                .select(.threadId, .server, .roomToken, .publicKey)
                .asRequest(of: OpenGroupUrlInfo.self)
                .fetchOne(db)
            
            guard let urlInfo: OpenGroupUrlInfo = maybeUrlInfo else { return nil }
            
            let capabilities: Set<Capability.Variant> = (try? Capability
                .select(.variant)
                .filter(Capability.Columns.openGroupServer == urlInfo.server.lowercased())
                .asRequest(of: Capability.Variant.self)
                .fetchSet(db))
                .defaulting(to: [])
            
            return OpenGroupCapabilityInfo(
                urlInfo: urlInfo,
                capabilities: capabilities
            )
        }
        
        public static func fetchAll(_ db: Database, ids: [String]) throws -> [OpenGroupCapabilityInfo] {
            let allUrlInfo: [OpenGroupUrlInfo] = try OpenGroup
                .filter(ids: ids)
                .select(.threadId, .server, .roomToken, .publicKey)
                .asRequest(of: OpenGroupUrlInfo.self)
                .fetchAll(db)
            
            guard !allUrlInfo.isEmpty else { return [] }
            
            return allUrlInfo.map { urlInfo -> OpenGroupCapabilityInfo in
                let capabilities: Set<Capability.Variant> = (try? Capability
                    .select(.variant)
                    .filter(Capability.Columns.openGroupServer == urlInfo.server.lowercased())
                    .asRequest(of: Capability.Variant.self)
                    .fetchSet(db))
                    .defaulting(to: [])
                
                return OpenGroupCapabilityInfo(
                    urlInfo: urlInfo,
                    capabilities: capabilities
                )
            }
        }
    }
}

// MARK: - LibSessionRespondingViewController

public protocol LibSessionRespondingViewController {
    var isConversationList: Bool { get }
    
    func isConversation(in threadIds: [String]) -> Bool
    func forceRefreshIfNeeded()
}

public extension LibSessionRespondingViewController {
    var isConversationList: Bool { false }
    
    func isConversation(in threadIds: [String]) -> Bool { return false }
    func forceRefreshIfNeeded() {}
}

// MARK: - Preferences.NotificationMode

private extension Preferences.NotificationMode {
    init(libSessionValue: CONVO_NOTIFY_MODE, threadVariant: SessionThread.Variant) {
        switch libSessionValue {
            case CONVO_NOTIFY_DEFAULT: self = .defaultMode(for: threadVariant)
            case CONVO_NOTIFY_ALL: self = .all
            case CONVO_NOTIFY_DISABLED: self = .none
            case CONVO_NOTIFY_MENTIONS_ONLY: self = .mentionsOnly
                
            default: self = .defaultMode(for: threadVariant)
        }
    }
}
