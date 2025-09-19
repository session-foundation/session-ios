// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import GRDB
import SessionUIKit
import SessionNetworkingKit
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
        SessionThread.Columns.shouldBeVisible,
        SessionThread.Columns.onlyNotifyForMentions,
        SessionThread.Columns.mutedUntilTimestamp
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
        _ db: ObservingDatabase,
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
                                        ContactUpdateInfo(
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
                            
                            remainingThreads.forEach { thread in
                                db.addEvent(
                                    ConversationEvent(
                                        id: thread.id,
                                        change: .pinnedPriority(
                                            thread.pinnedPriority
                                                .map { Int32($0 == 0 ? LibSession.visiblePriority : max($0, 1)) }
                                                .defaulting(to: LibSession.visiblePriority)
                                        )
                                    ),
                                    forKey: .conversationUpdated(thread.id)
                                )
                            }
                        }
                    }
                    
                case .community:
                    try dependencies.mutate(cache: .libSession) { cache in
                        try cache.performAndPushChange(db, for: .userGroups, sessionId: userSessionId) { config in
                            try LibSession.upsert(
                                communities: threads
                                    .compactMap { thread -> CommunityUpdateInfo? in
                                        urlInfo[thread.id].map { urlInfo in
                                            CommunityUpdateInfo(
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

public extension LibSession.Cache {
    func canPerformChange(
        threadId: String,
        threadVariant: SessionThread.Variant,
        changeTimestampMs: Int64
    ) -> Bool {
        let variant: ConfigDump.Variant = {
            switch threadVariant {
                case .contact: return (threadId == userSessionId.hexString ? .userProfile : .contacts)
                case .legacyGroup, .group, .community: return .userGroups
            }
        }()
        
        let configDumpTimestamp: TimeInterval = dependencies[singleton: .extensionHelper]
            .lastUpdatedTimestamp(for: userSessionId, variant: variant)
        let configDumpTimestampMs: Int64 = Int64(configDumpTimestamp * 1000)
        
        /// Ensure the change occurred after the last config message was handled (minus the buffer period)
        return (changeTimestampMs >= (configDumpTimestampMs - LibSession.configChangeBufferPeriodMs))
    }
    
    func conversationInConfig(
        threadId: String,
        threadVariant: SessionThread.Variant,
        visibleOnly: Bool,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
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
        
        switch threadVariant {
            case .contact where threadId == userSessionId.hexString:
                guard case .userProfile(let conf) = config(for: .userProfile, sessionId: userSessionId) else {
                    return false
                }
                
                return (
                    !visibleOnly ||
                    LibSession.shouldBeVisible(priority: user_profile_get_nts_priority(conf))
                )
            
            case .contact:
                var contact: contacts_contact = contacts_contact()
                
                guard case .contacts(let conf) = config(for: .contacts, sessionId: userSessionId) else {
                    return false
                }
                guard contacts_get(conf, &contact, &cThreadId) else {
                    LibSessionError.clear(conf)
                    return false
                }
                
                /// If the user opens a conversation with an existing contact but doesn't send them a message
                /// then the one-to-one conversation should remain hidden so we want to delete the `SessionThread`
                /// when leaving the conversation
                return (!visibleOnly || LibSession.shouldBeVisible(priority: contact.priority))
                
            case .community:
                guard
                    let urlInfo: LibSession.OpenGroupUrlInfo = openGroupUrlInfo,
                    var cBaseUrl: [CChar] = urlInfo.server.cString(using: .utf8),
                    var cRoom: [CChar] = urlInfo.roomToken.cString(using: .utf8),
                    case .userGroups(let conf) = config(for: .userGroups, sessionId: userSessionId)
                else { return false }
                
                var community: ugroups_community_info = ugroups_community_info()
                
                /// Not handling the `hidden` behaviour for communities so just indicate the existence
                let result: Bool = user_groups_get_community(conf, &community, &cBaseUrl, &cRoom)
                LibSessionError.clear(conf)
                
                return result
                
            case .group:
                guard case .userGroups(let conf) = config(for: .userGroups, sessionId: userSessionId) else {
                    return false
                }
                
                var group: ugroups_group_info = ugroups_group_info()
                
                /// Not handling the `hidden` behaviour for legacy groups so just indicate the existence
                return user_groups_get_group(conf, &group, &cThreadId)
                
            case .legacyGroup:
                guard case .userGroups(let conf) = config(for: .userGroups, sessionId: userSessionId) else {
                    return false
                }
                
                let groupInfo: UnsafeMutablePointer<ugroups_legacy_group_info>? = user_groups_get_legacy_group(conf, &cThreadId)
                LibSessionError.clear(conf)
                
                /// Not handling the `hidden` behaviour for legacy groups so just indicate the existence
                if groupInfo != nil {
                    ugroups_legacy_group_free(groupInfo)
                    return true
                }
                
                return false
        }
    }
    
    func conversationDisplayName(
        threadId: String,
        threadVariant: SessionThread.Variant,
        contactProfile: Profile?,
        visibleMessage: VisibleMessage?,
        openGroupName: String?,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> String {
        var finalProfile: Profile? = contactProfile
        var finalOpenGroupName: String? = openGroupName
        var finalClosedGroupName: String?
        
        switch threadVariant {
            case .contact where threadId == userSessionId.hexString: break
            case .contact:
                guard contactProfile == nil else { break }
                
                finalProfile = profile(
                    contactId: threadId,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    visibleMessage: visibleMessage
                )
                
            case .community:
                guard
                    openGroupName == nil,
                    let urlInfo: LibSession.OpenGroupUrlInfo = openGroupUrlInfo,
                    var cBaseUrl: [CChar] = urlInfo.server.cString(using: .utf8),
                    var cRoom: [CChar] = urlInfo.roomToken.cString(using: .utf8),
                    case .userGroups(let conf) = config(for: .userGroups, sessionId: userSessionId)
                else { break }
                
                var community: ugroups_community_info = ugroups_community_info()
                
                guard user_groups_get_community(conf, &community, &cBaseUrl, &cRoom) else {
                    LibSessionError.clear(conf)
                    break
                }
                
                finalOpenGroupName = community.get(\.room).nullIfEmpty
                
            case .group:
                guard var cThreadId: [CChar] = threadId.cString(using: .utf8) else { break }
                
                /// For a group try to extract the name from a `GroupInfo` config first, falling back to the `UserGroups` config
                guard
                    case .groupInfo(let conf) = config(for: .groupInfo, sessionId: SessionId(.group, hex: threadId)),
                    let groupNamePtr: UnsafePointer<CChar> = groups_info_get_name(conf)
                else {
                    guard case .userGroups(let conf) = config(for: .userGroups, sessionId: userSessionId) else {
                        break
                    }
                    
                    var group: ugroups_group_info = ugroups_group_info()
                    
                    guard user_groups_get_group(conf, &group, &cThreadId) else {
                        LibSessionError.clear(conf)
                        break
                    }
                    
                    finalClosedGroupName = group.get(\.name).nullIfEmpty
                    break
                }
                
                finalClosedGroupName = String(cString: groupNamePtr)
                
            case .legacyGroup:
                guard
                    case .userGroups(let conf) = config(for: .userGroups, sessionId: userSessionId),
                    var cThreadId: [CChar] = threadId.cString(using: .utf8)
                else { break }
                
                let groupInfo: UnsafeMutablePointer<ugroups_legacy_group_info>? = user_groups_get_legacy_group(conf, &cThreadId)
                LibSessionError.clear(conf)
                
                defer {
                    if groupInfo != nil {
                        ugroups_legacy_group_free(groupInfo)
                    }
                }
                
                finalClosedGroupName = groupInfo?.get(\.name).nullIfEmpty
        }
        
        return SessionThread.displayName(
            threadId: threadId,
            variant: threadVariant,
            closedGroupName: finalClosedGroupName,
            openGroupName: finalOpenGroupName,
            isNoteToSelf: (threadId == userSessionId.hexString),
            ignoringNickname: false,
            profile: finalProfile
        )
    }
    
    func isMessageRequest(
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> Bool {
        guard var cThreadId: [CChar] = threadId.cString(using: .utf8) else { return true }
        
        switch threadVariant {
            case .community, .legacyGroup: return false
            case .contact where threadId == userSessionId.hexString: return false
            case .contact:
                var contact: contacts_contact = contacts_contact()
                
                guard case .contacts(let conf) = config(for: .contacts, sessionId: userSessionId) else {
                    return true
                }
                guard contacts_get(conf, &contact, &cThreadId) else {
                    LibSessionError.clear(conf)
                    return true
                }
                
                return !contact.approved
                
            case .group:
                var group: ugroups_group_info = ugroups_group_info()
                
                guard case .userGroups(let conf) = config(for: .userGroups, sessionId: userSessionId) else {
                    return true
                }
                
                guard user_groups_get_group(conf, &group, &cThreadId) else {
                    LibSessionError.clear(conf)
                    return true
                }
                
                return group.invited
        }
    }
    
    func pinnedPriority(
        threadId: String,
        threadVariant: SessionThread.Variant,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?
    ) -> Int32 {
        guard var cThreadId: [CChar] = threadId.cString(using: .utf8) else {
            return LibSession.defaultNewThreadPriority
        }
        
        switch threadVariant {
            case .contact where threadId == userSessionId.hexString:
                guard case .userProfile(let conf) = config(for: .userProfile, sessionId: userSessionId) else {
                    return LibSession.defaultNewThreadPriority
                }
                
                return user_profile_get_nts_priority(conf)
                
            case .contact:
                var contact: contacts_contact = contacts_contact()
                
                guard case .contacts(let conf) = config(for: .contacts, sessionId: userSessionId) else {
                    return LibSession.defaultNewThreadPriority
                }
                guard contacts_get(conf, &contact, &cThreadId) else {
                    LibSessionError.clear(conf)
                    return LibSession.defaultNewThreadPriority
                }
                
                return contact.priority
                
            case .community:
                guard
                    let urlInfo: LibSession.OpenGroupUrlInfo = openGroupUrlInfo,
                    var cBaseUrl: [CChar] = urlInfo.server.cString(using: .utf8),
                    var cRoom: [CChar] = urlInfo.roomToken.cString(using: .utf8),
                    case .userGroups(let conf) = config(for: .userGroups, sessionId: userSessionId)
                else { return LibSession.defaultNewThreadPriority }
                
                var community: ugroups_community_info = ugroups_community_info()
                _ = user_groups_get_community(conf, &community, &cBaseUrl, &cRoom)
                LibSessionError.clear(conf)
                
                return community.priority
            
            case .legacyGroup:
                guard case .userGroups(let conf) = config(for: .userGroups, sessionId: userSessionId) else {
                    return LibSession.defaultNewThreadPriority
                }
                
                let groupInfo: UnsafeMutablePointer<ugroups_legacy_group_info>? = user_groups_get_legacy_group(conf, &cThreadId)
                LibSessionError.clear(conf)
                
                defer {
                    if groupInfo != nil {
                        ugroups_legacy_group_free(groupInfo)
                    }
                }
                
                return (groupInfo?.pointee.priority ?? LibSession.defaultNewThreadPriority)
                
            case .group:
                guard case .userGroups(let conf) = config(for: .userGroups, sessionId: userSessionId) else {
                    return LibSession.defaultNewThreadPriority
                }
                
                var group: ugroups_group_info = ugroups_group_info()
                _ = user_groups_get_group(conf, &group, &cThreadId)
                LibSessionError.clear(conf)
                
                return group.priority
        }
    }
    
    func disappearingMessagesConfig(
        threadId: String,
        threadVariant: SessionThread.Variant
    ) -> DisappearingMessagesConfiguration? {
        guard var cThreadId: [CChar] = threadId.cString(using: .utf8) else { return nil }
        
        switch threadVariant {
            case .community: return nil
            case .contact where threadId == userSessionId.hexString:
                guard case .userProfile(let conf) = config(for: .userProfile, sessionId: userSessionId) else {
                    return nil
                }
                
                let targetExpiry: Int32 = user_profile_get_nts_expiry(conf)
                let targetIsEnabled: Bool = (targetExpiry > 0)
                
                return DisappearingMessagesConfiguration(
                    threadId: threadId,
                    isEnabled: targetIsEnabled,
                    durationSeconds: TimeInterval(targetExpiry),
                    type: targetIsEnabled ? .disappearAfterSend : .unknown
                )
                
            case .contact:
                var contact: contacts_contact = contacts_contact()
                
                guard case .contacts(let conf) = config(for: .contacts, sessionId: userSessionId) else {
                    return nil
                }
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
                
            case .legacyGroup:
                guard case .userGroups(let conf) = config(for: .userGroups, sessionId: userSessionId) else {
                    return nil
                }
                
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
                
            case .group:
                guard
                    let groupSessionId: SessionId = try? SessionId(from: threadId),
                    groupSessionId.prefix == .group,
                    case .groupInfo(let conf) = config(for: .groupInfo, sessionId: groupSessionId)
                else { return nil }
                
                let durationSeconds: Int32 = groups_info_get_expiry_timer(conf)
                
                return DisappearingMessagesConfiguration(
                    threadId: threadId,
                    isEnabled: (durationSeconds > 0),
                    durationSeconds: TimeInterval(durationSeconds),
                    type: .disappearAfterSend
                )
        }
    }
    
    func displayPictureUrl(threadId: String, threadVariant: SessionThread.Variant) -> String? {
        switch threadVariant {
            case .contact where threadId == userSessionId.hexString:
                guard case .userProfile(let conf) = config(for: .userProfile, sessionId: userSessionId) else {
                    return nil
                }
                
                let profilePic: user_profile_pic = user_profile_get_pic(conf)
                return profilePic.get(\.url, nullIfEmpty: true)
                
            case .contact:
                var contact: contacts_contact = contacts_contact()
                
                guard case .contacts(let conf) = config(for: .contacts, sessionId: userSessionId) else {
                    return nil
                }
                guard
                    var cThreadId: [CChar] = threadId.cString(using: .utf8),
                    contacts_get(conf, &contact, &cThreadId)
                else {
                    LibSessionError.clear(conf)
                    return nil
                }
                
                return contact.get(\.profile_pic.url, nullIfEmpty: true)
                
            case .group:
                guard case .groupInfo(let conf) = config(for: .groupInfo, sessionId: SessionId(.group, hex: threadId)) else {
                    return nil
                }
                
                let profilePic: user_profile_pic = groups_info_get_pic(conf)
                return profilePic.get(\.url, nullIfEmpty: true)
                
            case .legacyGroup, .community: return nil
        }
    }
    
    func profile(
        contactId: String,
        threadId: String?,
        threadVariant: SessionThread.Variant?,
        visibleMessage: VisibleMessage?
    ) -> Profile? {
        // FIXME: Once `libSession` manages unsynced "Profile" data we should source this from there
        /// Extract the `displayName` directly from the `VisibleMessage` if available and it was sent by the desired contact
        let displayNameInMessage: String? = (visibleMessage?.sender != contactId ? nil :
            visibleMessage?.profile?.displayName?.nullIfEmpty
        )
        let fallbackProfile: Profile? = displayNameInMessage.map { Profile(id: contactId, name: $0) }
        
        guard var cContactId: [CChar] = contactId.cString(using: .utf8) else {
            return fallbackProfile
        }
        
        /// If we are trying to retrive the profile for the current user then we need to extract it from the `UserProfile` config
        guard contactId != userSessionId.hexString else {
            guard
                case .userProfile(let conf) = config(for: .userProfile, sessionId: userSessionId),
                let profileNamePtr: UnsafePointer<CChar> = user_profile_get_name(conf)
            else {
                return nil
            }
            
            let displayPic: user_profile_pic = user_profile_get_pic(conf)
            let displayPictureUrl: String? = displayPic.get(\.url, nullIfEmpty: true)
            
            return Profile(
                id: contactId,
                name: String(cString: profileNamePtr),
                lastNameUpdate: nil,
                nickname: nil,
                displayPictureUrl: displayPictureUrl,
                displayPictureEncryptionKey: (displayPictureUrl == nil ? nil : displayPic.get(\.key)),
                displayPictureLastUpdated: nil
            )
        }
        
        /// Define a function to extract a profile from the `GroupMembers` config, if we can't get a direct name for the contact and it's
        /// a group conversation then be might be able to source it from there
        func extractGroupMembersProfile() -> Profile? {
            guard
                threadVariant == .group,
                let threadId: String = threadId,
                case .groupMembers(let conf) = config(for: .groupMembers, sessionId: SessionId(.group, hex: threadId))
            else { return nil }
            
            var member: config_group_member = config_group_member()
            
            guard groups_members_get(conf, &member, &cContactId) else {
                LibSessionError.clear(conf)
                return fallbackProfile
            }
            
            let displayPictureUrl: String? = member.get(\.profile_pic.url, nullIfEmpty: true)
            
            /// The `displayNameInMessage` value is likely newer than the `name` value in the config so use that if available
            return Profile(
                id: contactId,
                name: (displayNameInMessage ?? member.get(\.name)),
                lastNameUpdate: nil,
                nickname: nil,
                displayPictureUrl: displayPictureUrl,
                displayPictureEncryptionKey: (displayPictureUrl == nil ? nil : member.get(\.profile_pic.key)),
                displayPictureLastUpdated: nil
            )
        }
        
        /// Try to extract profile information from the `Contacts` config
        guard case .contacts(let conf) = config(for: .contacts, sessionId: userSessionId) else {
            return extractGroupMembersProfile()
        }
        
        var contact: contacts_contact = contacts_contact()
        
        guard contacts_get(conf, &contact, &cContactId) else {
            LibSessionError.clear(conf)
            return extractGroupMembersProfile()
        }
        
        let displayPictureUrl: String? = contact.get(\.profile_pic.url, nullIfEmpty: true)
        
        /// The `displayNameInMessage` value is likely newer than the `name` value in the config so use that if available
        return Profile(
            id: contactId,
            name: (displayNameInMessage ?? contact.get(\.name)),
            lastNameUpdate: nil,
            nickname: contact.get(\.nickname, nullIfEmpty: true),
            displayPictureUrl: displayPictureUrl,
            displayPictureEncryptionKey: (displayPictureUrl == nil ? nil : contact.get(\.profile_pic.key)),
            displayPictureLastUpdated: nil
        )
    }
    
    func groupName(groupSessionId: SessionId) -> String? {
        guard
            case .userGroups(let conf) = config(for: .userGroups, sessionId: userSessionId),
            var cGroupId: [CChar] = groupSessionId.hexString.cString(using: .utf8)
        else { return nil }

        var group: ugroups_group_info = ugroups_group_info()
        
        guard user_groups_get_group(conf, &group, &cGroupId) else {
            LibSessionError.clear(conf)
            
            guard let legacyGroup: UnsafeMutablePointer<ugroups_legacy_group_info> = user_groups_get_legacy_group(conf, &cGroupId) else {
                LibSessionError.clear(conf)
                return nil
            }
            
            defer { ugroups_legacy_group_free(legacyGroup) }
            return legacyGroup.get(\.name)
        }
        
        return group.get(\.name)
    }
}

// MARK: - Convenience

public extension Dependencies {
    func set(_ db: ObservingDatabase, _ key: Setting.BoolKey, _ value: Bool?) {
        let targetVariant: ConfigDump.Variant
        
        switch key {
            case .checkForCommunityMessageRequests: targetVariant = .userProfile
            default: targetVariant = .local
        }
        
        let mutation: LibSession.Mutation? = try? self.mutate(cache: .libSession) { cache in
            try cache.perform(for: targetVariant) {
                cache.set(key, value)
            }
        }

        try? mutation?.upsert(db)
    }
    
    private func set<T: LibSessionConvertibleEnum>(_ db: ObservingDatabase, _ key: Setting.EnumKey, _ value: T?) {
        let mutation: LibSession.Mutation? = try? self.mutate(cache: .libSession) { cache in
            try cache.perform(for: .local) {
                cache.set(key, value)
            }
        }

        try? mutation?.upsert(db)
    }
    
    func setAsync(_ key: Setting.BoolKey, _ value: Bool?, onComplete: (@MainActor () -> Void)? = nil) {
        Task(priority: .userInitiated) { [weak self] in
            await self?.set(key, value)
            
            if let onComplete {
                await MainActor.run {
                    onComplete()
                }
            }
        }
    }
    
    func setAsync<T: LibSessionConvertibleEnum>(_ key: Setting.EnumKey, _ value: T?, onComplete: (@MainActor () -> Void)? = nil) {
        Task(priority: .userInitiated) { [weak self] in
            await self?.set(key, value)
            
            if let onComplete {
                await MainActor.run {
                    onComplete()
                }
            }
        }
    }
    
    private func set(_ key: Setting.BoolKey, _ value: Bool?) async {
        let targetVariant: ConfigDump.Variant
        
        switch key {
            case .checkForCommunityMessageRequests: targetVariant = .userProfile
            default: targetVariant = .local
        }
        
        let mutation: LibSession.Mutation? = try? await self.mutateAsyncAware(cache: .libSession) { cache in
            try cache.perform(for: targetVariant) {
                cache.set(key, value)
            }
        }

        try? await self[singleton: .storage].writeAsync { db in
            try mutation?.upsert(db)
        }
    }
    
    private func set<T: LibSessionConvertibleEnum>(_ key: Setting.EnumKey, _ value: T?) async {
        let mutation: LibSession.Mutation? = try? await self.mutateAsyncAware(cache: .libSession) { cache in
            try cache.perform(for: .local) {
                cache.set(key, value)
            }
        }

        try? await self[singleton: .storage].writeAsync { db in
            try mutation?.upsert(db)
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
