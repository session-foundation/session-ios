// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUIKit
import SessionUtilitiesKit

public enum ConversationDataHelper {}

public extension ConversationDataCache {
    struct Context: Sendable, Equatable, Hashable {
        public enum Source: Sendable, Equatable, Hashable {
            case conversationList
            case messageList(threadId: String)
            case conversationSettings(threadId: String)
            case searchResults
        }
        
        let source: Source
        let requireFullRefresh: Bool
        let requireAuthMethodFetch: Bool
        let requiresMessageRequestCountUpdate: Bool
        let requiresInitialUnreadInteractionInfo: Bool
        let requireRecentReactionEmojiUpdate: Bool
        
        // MARK: - Initialization
        
        public init(
            source: Source,
            requireFullRefresh: Bool,
            requireAuthMethodFetch: Bool,
            requiresMessageRequestCountUpdate: Bool,
            requiresInitialUnreadInteractionInfo: Bool,
            requireRecentReactionEmojiUpdate: Bool
        ) {
            self.source = source
            self.requireFullRefresh = requireFullRefresh
            self.requireAuthMethodFetch = requireAuthMethodFetch
            self.requiresMessageRequestCountUpdate = requiresMessageRequestCountUpdate
            self.requiresInitialUnreadInteractionInfo = requiresInitialUnreadInteractionInfo
            self.requireRecentReactionEmojiUpdate = requireRecentReactionEmojiUpdate
        }
        
        // MARK: - Functions
        
        func insertedItemIds<ID>(_ requirements: ConversationDataHelper.FetchRequirements, as: ID.Type) -> Set<ID> {
            switch source {
                case .searchResults, .conversationSettings: return []
                case .conversationList: return (requirements.insertedThreadIds as? Set<ID> ?? [])
                case .messageList: return (requirements.insertedInteractionIds as? Set<ID> ?? [])
            }
        }
        
        func deletedItemIds<ID>(_ requirements: ConversationDataHelper.FetchRequirements, as: ID.Type) -> Set<ID> {
            switch source {
                case .searchResults, .conversationSettings: return []
                case .conversationList: return (requirements.deletedThreadIds as? Set<ID> ?? [])
                case .messageList: return (requirements.deletedInteractionIds as? Set<ID> ?? [])
            }
        }
    }
}

public extension ConversationDataHelper {
    static func determineFetchRequirements<Item: Identifiable>(
        for changes: EventChangeset,
        currentCache: ConversationDataCache,
        itemCache: [Item.ID: Item],
        loadPageEvent: LoadPageEvent?
    ) -> FetchRequirements {
        var requirements: FetchRequirements = FetchRequirements(
            requireAuthMethodFetch: currentCache.context.requireAuthMethodFetch,
            requiresMessageRequestCountUpdate: currentCache.context.requiresMessageRequestCountUpdate,
            requiresInitialUnreadInteractionInfo: currentCache.context.requiresInitialUnreadInteractionInfo,
            requireRecentReactionEmojiUpdate: (
                currentCache.context.requireRecentReactionEmojiUpdate ||
                changes.contains(.recentReactionsUpdated)
            )
        )
        
        /// Validate we have the bear minimum data for the source
        switch currentCache.context.source {
            case .conversationList, .searchResults: break
            case .messageList(let threadId), .conversationSettings(let threadId):
                /// On the message list and conversation settings if we don't currently have the thread cached then we need to fetch it
                guard currentCache.thread(for: threadId) == nil else { break }
                
                requirements.threadIdsNeedingFetch.insert(threadId)
        }
        
        /// If we need a full fetch then we need to fill the "idsNeedingFetch" sets with info from the current cache
        if currentCache.context.requireFullRefresh {
            requirements.threadIdsNeedingFetch.insert(contentsOf: Set(currentCache.threads.keys))
            requirements.interactionIdsNeedingFetch.insert(contentsOf: Set(currentCache.interactions.keys))
            
            switch currentCache.context.source {
                case .searchResults: break
                case .conversationList:
                    requirements.threadIdsNeedingFetch.insert(contentsOf: Set(itemCache.keys) as? Set<String>)
                    
                case .messageList(let threadId):
                    requirements.threadIdsNeedingFetch.insert(threadId)
                    requirements.interactionIdsNeedingFetch.insert(contentsOf: Set(itemCache.keys) as? Set<Int64>)
                    
                case .conversationSettings(let threadId):
                    requirements.threadIdsNeedingFetch.insert(threadId)
            }
        }
        
        /// Handle explicit events which may require additional data to be fetched
        changes.databaseEvents.forEach { event in
            switch (event.key.generic, event.value) {
                case (GenericObservableKey(.messageRequestAccepted), let threadId as String):
                    requirements.threadIdsNeedingFetch.insert(threadId)
                    
                case (_, is ConversationEvent):
                    handleConversationEvent(
                        event,
                        cache: currentCache,
                        itemCache: itemCache,
                        requirements: &requirements
                    )
                    
                case (_, is MessageEvent):
                    handleMessageEvent(
                        event,
                        cache: currentCache,
                        requirements: &requirements
                    )
                    
                /// Blocking and unblocking contacts should result in the conversation being removed/added to the conversation list
                ///
                /// **Note:** This is generally observed via `anyContactBlockedStatusChanged`
                case (_, let contactEvent as ContactEvent):
                    if case .isBlocked(true) = contactEvent.change {
                        requirements.deletedThreadIds.insert(contactEvent.id)
                    }
                    else if case .isBlocked(false) = contactEvent.change {
                        requirements.insertedThreadIds.insert(contactEvent.id)
                    }
                    
                case (_, let groupMemberEvent as GroupMemberEvent):
                    requirements.groupIdsNeedingMemberFetch.insert(groupMemberEvent.threadId)
                    
                case (_, let profileEvent as ProfileEvent):
                    /// Only fetch if not already cached
                    if currentCache.profile(for: profileEvent.id) == nil {
                        requirements.profileIdsNeedingFetch.insert(profileEvent.id)
                    }
                    
                case (_, let attachmentEvent as AttachmentEvent):
                    requirements.attachmentIdsNeedingFetch.insert(attachmentEvent.id)
                    
                case (_, let reactionEvent as ReactionEvent):
                    requirements.interactionIdsNeedingReactionUpdates.insert(reactionEvent.messageId)
                
                default: break
            }
        }
        
        /// Handle any events which require a change to the message request count
        requirements.requiresMessageRequestCountUpdate = changes.databaseEvents.contains { event in
            switch event.key {
                case .messageRequestUnreadMessageReceived, .messageRequestAccepted, .messageRequestDeleted,
                    .messageRequestMessageRead:
                    return true
                    
                default: return false
            }
        }
        
        /// Handle page loading events based on view context
        requirements.needsPageLoad = {
            switch currentCache.context.source {
                case .conversationSettings, .searchResults: return false    /// No paging
                case .messageList, .conversationList: break
            }
            
            /// If we need a full refresh then we also need to refetch the paged data in case the sorting changed
            if currentCache.context.requireFullRefresh {
                return true
            }
            
            /// If we had an event that directly impacted the paged data then we need a page load
            let hasDirectPagedDataChange: Bool = (
                loadPageEvent != nil ||
                !currentCache.context.insertedItemIds(requirements, as: Item.ID.self).isEmpty ||
                !currentCache.context.deletedItemIds(requirements, as: Item.ID.self).isEmpty
            )
            
            if hasDirectPagedDataChange {
                return true
            }
            
            switch currentCache.context.source {
                case .messageList, .searchResults, .conversationSettings: return false
                case .conversationList:
                    /// On the conversation list if a new message is created in any conversation then we need to reload the paged
                    /// data as it means the conversation order likely changed
                    if changes.contains(.anyMessageCreatedInAnyConversation) {
                        return true
                    }
                    
                    /// On the conversation list if the last message was deleted then we need to reload the paged data as it means
                    /// the conversation order likely changed
                    for key in itemCache.keys {
                        guard
                            let threadId: String = key as? String,
                            let stats: ConversationInfoViewModel.InteractionStats = currentCache.interactionStats(
                                for: threadId
                            ),
                            changes.contains(.messageDeleted(id: stats.latestInteractionId, threadId: threadId))
                        else { continue }
                        
                        return true
                    }
                    
                    break
            }
            
            return false
        }()
        
        return requirements
    }
    
    static func applyNonDatabaseEvents(
        _ changes: EventChangeset,
        currentCache: ConversationDataCache,
        using dependencies: Dependencies
    ) async -> ConversationDataCache {
        var updatedCache: ConversationDataCache = currentCache
        
        /// We sacrifice a little memory and performance here to simplify the logic greatly, always refresh the `currentUserSessionIds`
        /// and `communityModAdminIds` to match the latest data stored in the `CommunityManager`
        let communityServers: [String: CommunityManager.Server] = await dependencies[singleton: .communityManager]
            .serversByThreadId()
        updatedCache.setCurrentUserSessionIds(communityServers.mapValues { $0.currentUserSessionIds })
        updatedCache.insert(
            communityModAdminIds: communityServers.values.reduce(into: [:]) { result, next in
                for room in next.rooms.values {
                    result[OpenGroup.idFor(roomToken: room.token, server: next.server)] = CommunityManager.allModeratorsAndAdmins(
                        room: room,
                        includingHidden: true
                    )
                }
            }
        )
        
        /// General Conversation Changes
        changes.forEach(.conversationUpdated, as: ConversationEvent.self) { event in
            switch (event.variant, event.change) {
                case (.group, .displayName(let name)):
                    guard let group: ClosedGroup = updatedCache.group(for: event.id) else { return }
                    
                    updatedCache.insert(group.with(name: .set(to: name)))
                    
                case (.community, .displayName(let name)):
                    guard let community: OpenGroup = updatedCache.community(for: event.id) else { return }
                    
                    updatedCache.insert(community.with(name: .set(to: name)))
                    
                case (.group, .description(let description)):
                    guard let group: ClosedGroup = updatedCache.group(for: event.id) else { return }
                    
                    updatedCache.insert(group.with(groupDescription: .set(to: description)))
                    
                case (.community, .description(let description)):
                    guard let community: OpenGroup = updatedCache.community(for: event.id) else { return }
                    
                    updatedCache.insert(community.with(roomDescription: .set(to: description)))
                    
                case (.group, .displayPictureUrl(let url)):
                    guard let group: ClosedGroup = updatedCache.group(for: event.id) else { return }
                    
                    updatedCache.insert(group.with(displayPictureUrl: .set(to: url)))
                    
                case (.community, .displayPictureUrl(let url)):
                    guard let community: OpenGroup = updatedCache.community(for: event.id) else { return }
                    
                    updatedCache.insert(community.with(displayPictureOriginalUrl: .set(to: url)))
                    
                case (_, .pinnedPriority(let value)):
                    guard let thread: SessionThread = updatedCache.thread(for: event.id) else { return }
                    
                    updatedCache.insert(thread.with(pinnedPriority: .set(to: value)))
                    
                case (_, .shouldBeVisible(let value)):
                    guard let thread: SessionThread = updatedCache.thread(for: event.id) else { return }
                    
                    updatedCache.insert(thread.with(shouldBeVisible: .set(to: value)))
                    
                case (_, .mutedUntilTimestamp(let value)):
                    guard let thread: SessionThread = updatedCache.thread(for: event.id) else { return }
                    
                    updatedCache.insert(thread.with(mutedUntilTimestamp: .set(to: value)))
                    
                case (_, .onlyNotifyForMentions(let value)):
                    guard let thread: SessionThread = updatedCache.thread(for: event.id) else { return }
                    
                    updatedCache.insert(thread.with(onlyNotifyForMentions: .set(to: value)))
                    
                case (_, .markedAsUnread(let value)):
                    guard let thread: SessionThread = updatedCache.thread(for: event.id) else { return }
                    
                    updatedCache.insert(thread.with(markedAsUnread: .set(to: value)))
                    
                case (_, .isDraft(let value)):
                    guard let thread: SessionThread = updatedCache.thread(for: event.id) else { return }
                    
                    updatedCache.insert(thread.with(isDraft: .set(to: value)))
                    
                case (_, .messageDraft(let value)):
                    guard let thread: SessionThread = updatedCache.thread(for: event.id) else { return }
                    
                    updatedCache.insert(thread.with(messageDraft: .set(to: value)))
                    
                case (_, .disappearingMessageConfiguration(let value)):
                    guard let value: DisappearingMessagesConfiguration = value else { return }
                    
                    updatedCache.insert(disappearingMessagesConfigurations: [value])
                
                /// These need to be handled via a database query
                case (_, .unreadCount), (_, .none): return
                    
                /// These events can be ignored as they will be handled via profile changes
                case (.contact, .displayName), (.contact, .displayPictureUrl): return
                    
                /// These combinations are not supported so can be ignored
                case (.contact, .description), (.legacyGroup, _): return
            }
        }
        
        /// Profile changes
        changes.forEach(.profile, as: ProfileEvent.self) { event in
            /// This profile (somehow) isn't in the cache so ignore event updates (it'll be fetched from the database when we hit that query)
            guard var profile: Profile = updatedCache.profile(for: event.id) else { return }
            
            switch event.change {
                case .name(let name): profile = profile.with(name: name)
                case .nickname(let nickname): profile = profile.with(nickname: .set(to: nickname))
                case .displayPictureUrl(let url): profile = profile.with(displayPictureUrl: .set(to: url))
                case .proStatus(_, let features, let proExpiryUnixTimestampMs, let proGenIndexHashHex):
                    /// **Note:** The final view model initialiser is responsible for mocking out or removing `proFeatures`
                    /// based on the dev settings
                    profile = profile.with(
                        proFeatures: .set(to: features),
                        proExpiryUnixTimestampMs: .set(to: proExpiryUnixTimestampMs),
                        proGenIndexHashHex: .set(to: proGenIndexHashHex)
                    )
            }
            
            updatedCache.insert(profile)
        }
        
        /// Contact Changes
        changes.forEach(.contact, as: ContactEvent.self) { event in
            switch event.change {
                case .isTrusted(let value):
                    guard let contact: Contact = updatedCache.contact(for: event.id) else { return }
                    
                    updatedCache.insert(contact.with(
                        isTrusted: .set(to: value),
                        currentUserSessionId: currentCache.userSessionId
                    ))
                    
                case .isApproved(let value):
                    guard let contact: Contact = updatedCache.contact(for: event.id) else { return }
                    
                    updatedCache.insert(contact.with(
                        isApproved: .set(to: value),
                        currentUserSessionId: currentCache.userSessionId
                    ))
                    
                case .isBlocked(let value):
                    guard let contact: Contact = updatedCache.contact(for: event.id) else { return }
                    
                    updatedCache.insert(contact.with(
                        isBlocked: .set(to: value),
                        currentUserSessionId: currentCache.userSessionId
                    ))
                    
                case .didApproveMe(let value):
                    guard let contact: Contact = updatedCache.contact(for: event.id) else { return }
                    
                    updatedCache.insert(contact.with(
                        didApproveMe: .set(to: value),
                        currentUserSessionId: currentCache.userSessionId
                    ))
                    
                case .unblinded: break  /// Needs custom handling
            }
        }
        
        /// Group Changes
        changes.forEach(.groupInfo, as: LibSession.GroupInfo.self) { info in
            updatedCache.insert(info)
        }
        
        changes.forEach(.groupMemberUpdated, as: GroupMemberEvent.self) { event in
            switch event.change {
                case .none: break
                case .role(let role, let status):
                    if event.profileId == currentCache.userSessionId.hexString {
                        updatedCache.insert(isUserModeratorOrAdmin: (role == .admin), in: event.threadId)
                    }
                    
                    var updatedMembers: [GroupMember] = updatedCache.groupMembers(for: event.threadId)
                    
                    if let memberIndex: Int = updatedMembers.firstIndex(where: { $0.profileId == event.profileId }) {
                        updatedMembers[memberIndex] = GroupMember(
                            groupId: event.threadId,
                            profileId: event.profileId,
                            role: role,
                            roleStatus: status,
                            isHidden: updatedMembers[memberIndex].isHidden
                        )
                        updatedCache.insert(groupMembers: [event.threadId: updatedMembers])
                    }
            }
        }
        
        /// Community changes
        changes.forEach(.communityUpdated, as: CommunityEvent.self) { event in
            switch event.change {
                case .capabilities(let capabilities):
                    updatedCache.insert(communityCapabilities: [event.id: Set(capabilities)])
                
                case .permissions(let read, let write, let upload):
                    guard let openGroup: OpenGroup = updatedCache.community(for: event.id) else { return }
                    
                    updatedCache.insert(
                        openGroup.with(
                            permissions: .set(to: OpenGroup.Permissions(
                                read: read,
                                write: write,
                                upload: upload
                            ))
                        )
                    )
                    
                case .role(let moderator, let admin, let hiddenModerator, let hiddenAdmin):
                    updatedCache.insert(
                        isUserModeratorOrAdmin: (moderator || admin || hiddenModerator || hiddenAdmin),
                        in: event.id
                    )
                
                case .moderatorsAndAdmins(let admins, let hiddenAdmins, let moderators, let hiddenModerators):
                    var combined: [String] = admins
                    combined.insert(contentsOf: hiddenAdmins, at: 0)
                    combined.insert(contentsOf: moderators, at: 0)
                    combined.insert(contentsOf: hiddenModerators, at: 0)
                    
                    let modAdminIds: Set<String> = Set(combined)
                    updatedCache.insert(communityModAdminIds: [event.id: modAdminIds])
                    updatedCache.insert(
                        isUserModeratorOrAdmin: !modAdminIds
                            .isDisjoint(with: updatedCache.currentUserSessionIds(for: event.id)),
                        in: event.id
                    )
                
                /// No need to do anything for these changes
                case .receivedInitialMessages: break
            }
        }
        
        /// General unblinding handling
        changes.forEach(.anyContactUnblinded, as: ContactEvent.self) { event in
            switch event.change {
                case .unblinded(let blindedId, let unblindedId):
                    updatedCache.insert(unblindedIdMap: [blindedId: unblindedId])
                
                default: break
            }
        }
        
        /// Typing indicators
        changes.forEach(.typingIndicator, as: TypingIndicatorEvent.self) { event in
            switch event.change {
                case .started: updatedCache.setTyping(true, in: event.threadId)
                case .stopped: updatedCache.setTyping(false, in: event.threadId)
            }
        }
        
        return updatedCache
    }
    
    static func fetchFromDatabase<ID>(
        _ db: ObservingDatabase,
        requirements: FetchRequirements,
        currentCache: ConversationDataCache,
        loadResult: PagedData.LoadResult<ID>,
        loadPageEvent: LoadPageEvent?,
        using dependencies: Dependencies
    ) throws -> (loadResult: PagedData.LoadResult<ID>, cache: ConversationDataCache) {
        guard requirements.needsAnyFetch else {
            return (loadResult, currentCache)
        }
        
        var updatedLoadResult: PagedData.LoadResult<ID> = loadResult
        var updatedCache: ConversationDataCache = currentCache
        var updatedRequirements: FetchRequirements = requirements.resettingExternalFetchFlags()
        
        /// Handle page loads first
        if updatedRequirements.needsPageLoad {
            let target: PagedData.Target<ID>
            
            switch (loadPageEvent?.target(with: loadResult), currentCache.context.source) {
                case (.some(let explicitTarget), _): target = explicitTarget
                case (.none, .searchResults), (.none, .conversationSettings): target = .newItems(insertedIds: [], deletedIds: [])
                case (.none, .conversationList):
                    target = .reloadCurrent(
                        insertedIds: currentCache.context.insertedItemIds(updatedRequirements, as: ID.self),
                        deletedIds: currentCache.context.deletedItemIds(updatedRequirements, as: ID.self)
                    )
                    
                case (.none, .messageList):
                    target = .newItems(
                        insertedIds: currentCache.context.insertedItemIds(updatedRequirements, as: ID.self),
                        deletedIds: currentCache.context.deletedItemIds(updatedRequirements, as: ID.self)
                    )
            }
            
            updatedLoadResult = try loadResult.load(db, target: target)
            updatedRequirements.needsPageLoad = false
        }
        
        switch currentCache.context.source {
            case .searchResults, .conversationSettings: break
            case .conversationList:
                if let newIds: [String] = updatedLoadResult.newIds as? [String], !newIds.isEmpty {
                    updatedRequirements.threadIdsNeedingFetch.insert(contentsOf: Set(newIds))
                    updatedRequirements.threadIdsNeedingInteractionStats.insert(contentsOf: Set(newIds))
                }
                
            case .messageList:
                if let newIds: [Int64] = updatedLoadResult.newIds as? [Int64], !newIds.isEmpty {
                    updatedRequirements.interactionIdsNeedingFetch.insert(contentsOf: Set(newIds))
                }
        }
        
        /// Now that we've finished the page load we can clear out the "insertedIds" sets (should only be used for the above)
        updatedRequirements.insertedThreadIds.removeAll()
        updatedRequirements.insertedInteractionIds.removeAll()
        
        /// Loop through the data until we no longer need to fetch anything
        ///
        /// **Note:** The code below _should_ only run once but it's dependant on being run in a specific order (as fetching one
        /// type can result in the need to fetch more data for other types). In order to avoid bugs being introduced in the future due
        /// to re-ordering the below we instead loop until there is nothing left to fetch.
        var loopCounter: Int = 0
        
        while updatedRequirements.needsAnyFetch {
            /// Fetch any required records and update the caches
            if !updatedRequirements.threadIdsNeedingFetch.isEmpty {
                let threads: [SessionThread] = try SessionThread
                    .filter(ids: updatedRequirements.threadIdsNeedingFetch)
                    .fetchAll(db)
                updatedCache.insert(threads: threads)
                updatedRequirements.threadIdsNeedingFetch.removeAll()
                
                /// Fetch the disappearing messages config for the conversation
                let disappearingConfigs: [DisappearingMessagesConfiguration] = try DisappearingMessagesConfiguration
                    .filter(ids: threads.map { $0.id })
                    .fetchAll(db)
                updatedCache.insert(disappearingMessagesConfigurations: disappearingConfigs)
                
                /// Fetch any associated data that isn't already cached
                threads.forEach { thread in
                    switch thread.variant {
                        case .contact:
                            if updatedCache.profile(for: thread.id) == nil || currentCache.context.requireFullRefresh {
                                updatedRequirements.profileIdsNeedingFetch.insert(thread.id)
                            }
                            
                            if updatedCache.contact(for: thread.id) == nil || currentCache.context.requireFullRefresh {
                                updatedRequirements.contactIdsNeedingFetch.insert(thread.id)
                            }
                            
                        case .group, .legacyGroup:
                            if updatedCache.group(for: thread.id) == nil || currentCache.context.requireFullRefresh {
                                updatedRequirements.groupIdsNeedingFetch.insert(thread.id)
                            }
                            
                            if updatedCache.groupMembers(for: thread.id).isEmpty || currentCache.context.requireFullRefresh {
                                updatedRequirements.groupIdsNeedingMemberFetch.insert(thread.id)
                            }
                            
                        case .community:
                            if updatedCache.community(for: thread.id) == nil || currentCache.context.requireFullRefresh {
                                updatedRequirements.communityIdsNeedingFetch.insert(thread.id)
                            }
                    }
                }
            }
            
            if !updatedRequirements.threadIdsNeedingInteractionStats.isEmpty {
                /// If we can't get the stats then it means the conversation has no more interactions which means we need to clear
                /// out any old stats for that conversation (otherwise it'll show the wrong unread count)
                let stats: [ConversationInfoViewModel.InteractionStats] = try ConversationInfoViewModel.InteractionStats
                    .request(for: updatedRequirements.threadIdsNeedingInteractionStats)
                    .fetchAll(db)
                updatedCache.insert(interactionStats: stats)
                updatedCache.remove(interactionStatsForThreadIds: updatedRequirements.threadIdsNeedingInteractionStats
                    .subtracting(Set(stats.map { $0.threadId })))
                
                updatedRequirements.interactionIdsNeedingFetch.insert(
                    contentsOf: Set(stats.map { $0.latestInteractionId })
                )
                updatedRequirements.threadIdsNeedingInteractionStats.removeAll()
            }
            
            if !updatedRequirements.interactionIdsNeedingFetch.isEmpty {
                /// If the source is `messageList` then before we fetch the interactions we need to get the ids of any quoted interactions
                ///
                /// **Note:** We may not be able to find the quoted interaction (hence the `Int64?` but would still want to render
                /// the message as a quote)
                switch currentCache.context.source {
                    case .conversationList, .conversationSettings, .searchResults: break
                    case .messageList(let threadId):
                        let quoteInteractionIdResults: Set<FetchablePair<Int64, Int64?>> = try MessageViewModel
                            .quotedInteractionIds(
                                for: updatedRequirements.interactionIdsNeedingFetch,
                                currentUserSessionIds: updatedCache.currentUserSessionIds(for: threadId)
                            )
                            .fetchSet(db)
                        
                        updatedCache.insert(quoteMap: quoteInteractionIdResults.reduce(into: [:]) { result, next in
                            result[next.first] = MessageViewModel.MaybeUnresolvedQuotedInfo(
                                foundQuotedInteractionId: next.second
                            )
                        })
                        updatedRequirements.interactionIdsNeedingFetch.insert(
                            contentsOf: Set(quoteInteractionIdResults.compactMap { $0.second })
                        )
                        
                        /// We want to just refetch all reactions (handling individual reaction events, especially with "pending"
                        /// reactions in SOGS, will likely result in bugs)
                        updatedRequirements.interactionIdsNeedingReactionUpdates.insert(
                            contentsOf: updatedRequirements.interactionIdsNeedingFetch
                        )
                }
                
                /// Now fetch the interactions
                let interactions: [Interaction] = try Interaction
                    .filter(ids: updatedRequirements.interactionIdsNeedingFetch)
                    .fetchAll(db)
                updatedCache.insert(interactions: interactions)
                updatedRequirements.interactionIdsNeedingFetch.removeAll()
                
                let attachmentMap: [Int64: Set<InteractionAttachment>] = try InteractionAttachment
                    .filter(interactions.map { $0.id }.contains(InteractionAttachment.Columns.interactionId))
                    .fetchAll(db)
                    .grouped(by: \.interactionId)
                    .mapValues { Set($0) }
                updatedCache.insert(attachmentMap: attachmentMap)
                
                /// In the `conversationList` we only care about the first attachment and the total number of attachments (for the
                /// snippet) so no need to fetch others
                let targetAttachmentIds: Set<String> = Set(attachmentMap.values
                    .flatMap { $0 }
                    .filter { interactionAttachment in
                        switch currentCache.context.source {
                            case .conversationList, .searchResults: return (interactionAttachment.albumIndex == 0)
                            case .messageList: return true
                            case .conversationSettings: return false
                        }
                    }
                    .map { $0.attachmentId })
                updatedRequirements.attachmentIdsNeedingFetch.insert(contentsOf: targetAttachmentIds)
                
                /// Fetch any link previews needed
                let linkPreviewLookupInfo: [(url: String, timestamp: Int64)] = interactions.compactMap {
                    guard let url: String = $0.linkPreviewUrl else { return nil }
                    
                    return (url, $0.timestampMs)
                }
                
                if !linkPreviewLookupInfo.isEmpty {
                    let urls: [String] = linkPreviewLookupInfo.map(\.url)
                    let minTimestampMs: Int64 = (linkPreviewLookupInfo.map(\.timestamp).min() ?? 0)
                    let maxTimestampMs: Int64 = (linkPreviewLookupInfo.map(\.timestamp).max() ?? Int64.max)
                    let finalMinTimestamp: TimeInterval = (TimeInterval(minTimestampMs / 1000) - LinkPreview.timstampResolution)
                    let finalMaxTimestamp: TimeInterval = (TimeInterval(maxTimestampMs / 1000) + LinkPreview.timstampResolution)
                    
                    let linkPreviews: [LinkPreview] = try LinkPreview
                        .filter(urls.contains(LinkPreview.Columns.url))
                        .filter(LinkPreview.Columns.timestamp > finalMinTimestamp)
                        .filter(LinkPreview.Columns.timestamp < finalMaxTimestamp)
                        .fetchAll(db)
                    updatedCache.insert(linkPreviews: linkPreviews)
                    updatedRequirements.attachmentIdsNeedingFetch.insert(
                        contentsOf: Set(linkPreviews.compactMap { $0.attachmentId })
                    )
                }
                
                /// If the interactions contain any profiles that we don't have cached then we need to fetch those as well
                interactions.forEach { interaction in
                    if updatedCache.profile(for: interaction.authorId) == nil {
                        updatedRequirements.profileIdsNeedingFetch.insert(interaction.authorId)
                    }
                    
                    MentionUtilities.allPubkeys(in: (interaction.body ?? "")).forEach { mentionedId in
                        if updatedCache.profile(for: mentionedId) == nil {
                            updatedRequirements.profileIdsNeedingFetch.insert(mentionedId)
                        }
                    }
                }
            }
            
            if !updatedRequirements.attachmentIdsNeedingFetch.isEmpty {
                let attachments: [Attachment] = try Attachment
                    .filter(ids: updatedRequirements.attachmentIdsNeedingFetch)
                    .fetchAll(db)
                updatedCache.insert(attachments: attachments)
                updatedRequirements.attachmentIdsNeedingFetch.removeAll()
            }
            
            if !updatedRequirements.interactionIdsNeedingReactionUpdates.isEmpty {
                let reactions: [Int64: [Reaction]] = try Reaction
                    .filter(updatedRequirements.interactionIdsNeedingReactionUpdates.contains(Reaction.Columns.interactionId))
                    .fetchAll(db)
                    .grouped(by: \.interactionId)
                updatedCache.insert(reactions: reactions)
                updatedRequirements.interactionIdsNeedingReactionUpdates.removeAll()
            }
            
            if !updatedRequirements.contactIdsNeedingFetch.isEmpty {
                let contacts: [Contact] = try Contact
                    .filter(ids: updatedRequirements.contactIdsNeedingFetch)
                    .fetchAll(db)
                updatedCache.insert(contacts: contacts)
                updatedRequirements.contactIdsNeedingFetch.removeAll()
                
                contacts.forEach { contact in
                    if updatedCache.profile(for: contact.id) == nil {
                        updatedRequirements.profileIdsNeedingFetch.insert(contact.id)
                    }
                }
            }
            
            if !updatedRequirements.groupIdsNeedingFetch.isEmpty {
                let groups: [ClosedGroup] = try ClosedGroup
                    .filter(ids: updatedRequirements.groupIdsNeedingFetch)
                    .fetchAll(db)
                updatedCache.insert(groups: groups)
                updatedRequirements.groupIdsNeedingFetch.removeAll()
                
                updatedRequirements.groupIdsNeedingMemberFetch.insert(contentsOf: Set(groups.map { $0.threadId }))
            }
            
            if !updatedRequirements.groupIdsNeedingMemberFetch.isEmpty {
                let groupMembers: [GroupMember] = try GroupMember
                    .filter(updatedRequirements.groupIdsNeedingMemberFetch.contains(GroupMember.Columns.groupId))
                    .fetchAll(db)
                updatedCache.insert(groupMembers: groupMembers.grouped(by: \.groupId))
                updatedRequirements.groupIdsNeedingMemberFetch.removeAll()
                
                groupMembers.forEach { member in
                    if updatedCache.profile(for: member.profileId) == nil {
                        updatedRequirements.profileIdsNeedingFetch.insert(member.profileId)
                    }
                }
            }
            
            if !updatedRequirements.communityIdsNeedingFetch.isEmpty {
                let communities: [OpenGroup] = try OpenGroup
                    .filter(ids: updatedRequirements.communityIdsNeedingFetch)
                    .fetchAll(db)
                updatedCache.insert(communities: communities)
                updatedRequirements.communityIdsNeedingFetch.removeAll()
                
                /// Also need to fetch capabilities if we don't have them cached for this server
                let communityServersNeedingCapabilityFetch: Set<String> = Set(communities.compactMap { openGroup in
                    guard updatedCache.communityCapabilities(for: openGroup.server).isEmpty else { return nil }
                    
                    return openGroup.server
                })
                
                if !communityServersNeedingCapabilityFetch.isEmpty {
                    let capabilities: [Capability] = try Capability
                        .filter(communityServersNeedingCapabilityFetch.contains(Capability.Columns.openGroupServer))
                        .fetchAll(db)
                    
                    updatedCache.insert(
                        communityCapabilities: capabilities
                            .grouped(by: \.openGroupServer)
                            .mapValues { capabilities in Set(capabilities.map { $0.variant }) }
                    )
                }
            }
            
            if !updatedRequirements.profileIdsNeedingFetch.isEmpty {
                let profiles: [Profile] = try Profile
                    .filter(ids: updatedRequirements.profileIdsNeedingFetch)
                    .fetchAll(db)
                updatedCache.insert(profiles: profiles)
                updatedRequirements.profileIdsNeedingFetch.removeAll()
                
                /// If the source is `messageList` or `conversationSettings` and we have blinded ids then we want to
                /// update the `unblindedIdMap` so that we can show a users unblinded profile information if possible
                let blindedIds: Set<String> = Set(profiles.map { $0.id }
                    .filter { SessionId.Prefix.isCommunityBlinded($0) })
                
                if !blindedIds.isEmpty {
                    switch currentCache.context.source {
                        case .conversationList, .searchResults: break
                        case .messageList, .conversationSettings:
                            let blindedIdMap: [String: String] = try BlindedIdLookup
                                .filter(ids: blindedIds)
                                .filter(BlindedIdLookup.Columns.sessionId != nil)
                                .fetchAll(db)
                                .reduce(into: [:]) { result, next in result[next.blindedId] = next.sessionId }
                            
                            updatedCache.insert(unblindedIdMap: blindedIdMap)
                    }
                }
            }
            
            loopCounter += 1
            
            guard loopCounter < 10 else {
                Log.critical("[ConversationDataHelper] We ended up looping 10 times trying to update the cache, something went wrong: \(updatedRequirements).")
                break
            }
        }
        
        /// Remove any values which are no longer needed
        updatedCache.remove(threadIds: updatedRequirements.deletedThreadIds)
        updatedCache.remove(interactionIds: updatedRequirements.deletedInteractionIds)
        
        return (updatedLoadResult, updatedCache)
    }
    
    /// This function currently assumes that it will be run after the `fetchFromDatabase` function - we may have to rework in the future
    /// to support additional data being sourced from `libSession` (potentially calling this both before and after `fetchFromDatabase`)
    static func fetchFromLibSession(
        requirements: FetchRequirements,
        cache: ConversationDataCache,
        using dependencies: Dependencies
    ) throws -> ConversationDataCache {
        var updatedCache: ConversationDataCache = cache
        let groupInfoIdsNeedingFetch: Set<String> = Set(cache.groups.keys)
            .filter { cache.groupInfo(for: $0) == nil }
        
        if !groupInfoIdsNeedingFetch.isEmpty {
            let groupInfo: [LibSession.GroupInfo?] = dependencies.mutate(cache: .libSession) { cache in
                cache.groupInfo(for: groupInfoIdsNeedingFetch)
            }
            
            updatedCache.insert(groupInfo: groupInfo.compactMap { $0 })
        }
        
        return updatedCache
    }
}

// MARK: - Convenience

public extension ConversationDataHelper {
    static func fetchFromDatabase(
        _ db: ObservingDatabase,
        requirements: FetchRequirements,
        currentCache: ConversationDataCache,
        using dependencies: Dependencies
    ) throws -> ConversationDataCache {
        return try fetchFromDatabase(
            db,
            requirements: requirements,
            currentCache: currentCache,
            loadResult: PagedData.LoadResult<String>.createInvalid(),
            loadPageEvent: nil,
            using: dependencies
        ).cache
    }
}

// MARK: - Specific Event Handling

private extension ConversationDataHelper {
    static func handleConversationEvent<Item: Identifiable>(
        _ event: ObservedEvent,
        cache: ConversationDataCache,
        itemCache: [Item.ID: Item],
        requirements: inout FetchRequirements
    ) {
        guard let conversationEvent: ConversationEvent = event.value as? ConversationEvent else { return }
        
        switch (event.key.generic, conversationEvent.change, cache.context.source) {
            case (.conversationCreated, _, _): requirements.insertedThreadIds.insert(conversationEvent.id)
            case (.conversationDeleted, _, _): requirements.deletedThreadIds.insert(conversationEvent.id)
                
            case (_, .disappearingMessageConfiguration, .messageList):
                /// Since we cache whether a messages disappearing message config can be followed we
                /// need to update the value if the disappearing message config on the conversation changes
                itemCache.forEach { _, item in
                    guard
                        let messageViewModel: MessageViewModel = item as? MessageViewModel,
                        messageViewModel.canFollowDisappearingMessagesSetting
                    else { return }
                    
                    requirements.interactionIdsNeedingFetch.insert(messageViewModel.id)
                }
                
            default: break
        }
    }
    
    static func handleMessageEvent(
        _ event: ObservedEvent,
        cache: ConversationDataCache,
        requirements: inout FetchRequirements
    ) {
        guard
            let messageEvent: MessageEvent = event.value as? MessageEvent,
            let interactionId: Int64 = messageEvent.id
        else { return }
        
        switch event.key.generic {
            case .messageCreated: requirements.insertedInteractionIds.insert(interactionId)
            case .messageUpdated: requirements.interactionIdsNeedingFetch.insert(interactionId)
            case .messageDeleted: requirements.deletedInteractionIds.insert(interactionId)
                
            case GenericObservableKey(.anyMessageCreatedInAnyConversation):
                requirements.insertedInteractionIds.insert(interactionId)
                
                /// If we don't currently have the thread in the cache then it's likely a thread from a page which hasn't been fetched
                /// yet, we now need to fetch it in case in now belongs in the current page
                if cache.thread(for: messageEvent.threadId) == nil {
                    requirements.insertedThreadIds.insert(messageEvent.threadId)
                }
                
            default: break
        }
        
        switch cache.context.source {
            case .conversationSettings, .searchResults: break
            case .conversationList, .messageList:
                /// Any message event means we need to refetch interaction stats and latest message
                requirements.threadIdsNeedingInteractionStats.insert(messageEvent.threadId)
        }
    }
}

// MARK: - FetchRequirements

public extension ConversationDataHelper {
    struct FetchRequirements {
        public var requireAuthMethodFetch: Bool
        public var requiresMessageRequestCountUpdate: Bool
        public var requiresInitialUnreadInteractionInfo: Bool
        public var requireRecentReactionEmojiUpdate: Bool
        fileprivate var needsPageLoad: Bool
        
        fileprivate var insertedThreadIds: Set<String>
        fileprivate var deletedThreadIds: Set<String>
        fileprivate var insertedInteractionIds: Set<Int64>
        fileprivate var deletedInteractionIds: Set<Int64>
        
        fileprivate var threadIdsNeedingFetch: Set<String>
        fileprivate var threadIdsNeedingInteractionStats: Set<String>
        fileprivate var contactIdsNeedingFetch: Set<String>
        fileprivate var groupIdsNeedingFetch: Set<String>
        fileprivate var groupIdsNeedingMemberFetch: Set<String>
        fileprivate var communityIdsNeedingFetch: Set<String>
        fileprivate var profileIdsNeedingFetch: Set<String>
        fileprivate var interactionIdsNeedingFetch: Set<Int64>
        fileprivate var interactionIdsNeedingReactionUpdates: Set<Int64>
        fileprivate var attachmentIdsNeedingFetch: Set<String>
        
        public var needsAnyFetch: Bool {
            requireAuthMethodFetch ||
            requiresMessageRequestCountUpdate ||
            requiresInitialUnreadInteractionInfo ||
            requireRecentReactionEmojiUpdate ||
            needsPageLoad ||
            !insertedThreadIds.isEmpty ||
            !insertedInteractionIds.isEmpty ||
            
            !threadIdsNeedingFetch.isEmpty ||
            !threadIdsNeedingInteractionStats.isEmpty ||
            !contactIdsNeedingFetch.isEmpty ||
            !groupIdsNeedingFetch.isEmpty ||
            !groupIdsNeedingMemberFetch.isEmpty ||
            !communityIdsNeedingFetch.isEmpty ||
            !profileIdsNeedingFetch.isEmpty ||
            !interactionIdsNeedingFetch.isEmpty ||
            !interactionIdsNeedingReactionUpdates.isEmpty ||
            !attachmentIdsNeedingFetch.isEmpty
        }
        
        public init(
            requireAuthMethodFetch: Bool,
            requiresMessageRequestCountUpdate: Bool,
            requiresInitialUnreadInteractionInfo: Bool,
            requireRecentReactionEmojiUpdate: Bool,
            needsPageLoad: Bool = false,
            insertedThreadIds: Set<String> = [],
            deletedThreadIds: Set<String> = [],
            insertedInteractionIds: Set<Int64> = [],
            deletedInteractionIds: Set<Int64> = [],
            threadIdsNeedingFetch: Set<String> = [],
            threadIdsNeedingInteractionStats: Set<String> = [],
            contactIdsNeedingFetch: Set<String> = [],
            groupIdsNeedingFetch: Set<String> = [],
            groupIdsNeedingMemberFetch: Set<String> = [],
            communityIdsNeedingFetch: Set<String> = [],
            profileIdsNeedingFetch: Set<String> = [],
            interactionIdsNeedingFetch: Set<Int64> = [],
            interactionIdsNeedingReactionUpdates: Set<Int64> = [],
            attachmentIdsNeedingFetch: Set<String> = []
        ) {
            self.requireAuthMethodFetch = requireAuthMethodFetch
            self.requiresMessageRequestCountUpdate = requiresMessageRequestCountUpdate
            self.requiresInitialUnreadInteractionInfo = requiresInitialUnreadInteractionInfo
            self.requireRecentReactionEmojiUpdate = requireRecentReactionEmojiUpdate
            self.needsPageLoad = needsPageLoad
            self.insertedThreadIds = insertedThreadIds
            self.deletedThreadIds = deletedThreadIds
            self.insertedInteractionIds = insertedInteractionIds
            self.deletedInteractionIds = deletedInteractionIds
            self.threadIdsNeedingFetch = threadIdsNeedingFetch
            self.threadIdsNeedingInteractionStats = threadIdsNeedingInteractionStats
            self.contactIdsNeedingFetch = contactIdsNeedingFetch
            self.groupIdsNeedingFetch = groupIdsNeedingFetch
            self.groupIdsNeedingMemberFetch = groupIdsNeedingMemberFetch
            self.communityIdsNeedingFetch = communityIdsNeedingFetch
            self.profileIdsNeedingFetch = profileIdsNeedingFetch
            self.interactionIdsNeedingFetch = interactionIdsNeedingFetch
            self.interactionIdsNeedingReactionUpdates = interactionIdsNeedingReactionUpdates
            self.attachmentIdsNeedingFetch = attachmentIdsNeedingFetch
        }
        
        public func resettingExternalFetchFlags() -> FetchRequirements {
            var result: FetchRequirements = self
            result.requireAuthMethodFetch = false
            result.requiresMessageRequestCountUpdate = false
            result.requiresInitialUnreadInteractionInfo = false
            result.requireRecentReactionEmojiUpdate = false
            
            return result
        }
    }
}
