// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUIKit
import SessionUtilitiesKit

public typealias ConversationDataCacheItemRequirements = (Sendable & Equatable & Hashable & Identifiable)

public struct ConversationDataCache: Sendable, Equatable, Hashable {
    public let userSessionId: SessionId
    public fileprivate(set) var context: Context
    
    // MARK: - General
    
    /// Stores `profileId -> Profile` (`threadId` for contact threads)
    public fileprivate(set) var profiles: [String: Profile] = [:]
    
    // MARK: - Thread Data
    
    /// Stores `threadId -> SessionThread`
    public fileprivate(set) var threads: [String: SessionThread] = [:]
    
    /// Stores `contactId -> Contact` (`threadId` for contact threads)
    public fileprivate(set) var contacts: [String: Contact] = [:]
    
    /// Stores `threadId -> ClosedGroup`
    public fileprivate(set) var groups: [String: ClosedGroup] = [:]
    
    /// Stores `threadId -> GroupInfo`
    public fileprivate(set) var groupInfo: [String: LibSession.GroupInfo] = [:]
    
    /// Stores `threadId -> members`
    public fileprivate(set) var groupMembers: [String: [GroupMember]] = [:]
    
    /// Stores `threadId -> OpenGroup`
    public fileprivate(set) var communities: [String: OpenGroup] = [:]
    
    /// Stores `openGroup.server -> capabilityVariants`
    public fileprivate(set) var communityCapabilities: [String: Set<Capability.Variant>] = [:]
    
    /// Stores `threadId -> modAdminIds`
    public fileprivate(set) var communityModAdminIds: [String: Set<String>] = [:]
    
    /// Stores `threadId -> isUserModeratorOrAdmin`
    public fileprivate(set) var userModeratorOrAdmin: [String: Bool] = [:]
    
    /// Stores `threadId -> DisappearingMessagesConfig`
    public fileprivate(set) var disappearingMessagesConfigurations: [String: DisappearingMessagesConfiguration] = [:]
    
    /// Stores `threadId -> interactionStats`
    public fileprivate(set) var interactionStats: [String: ConversationInfoViewModel.InteractionStats] = [:]
    
    /// Stores `threadId -> InteractionInfo` (the last interaction info for the thread)
    public fileprivate(set) var lastInteractions: [String: ConversationInfoViewModel.InteractionInfo] = [:]
    
    /// Stores `threadId -> currentUserSessionIds`
    public fileprivate(set) var currentUserSessionIds: [String: Set<String>] = [:]
    
    // MARK: - Message Data
    
    /// Stores `interactionId -> Interaction`
    public fileprivate(set) var interactions: [Int64: Interaction] = [:]
    
    /// Stores `interactionId -> interactionAttachments`
    public fileprivate(set) var attachmentMap: [Int64: Set<InteractionAttachment>] = [:]
    
    /// Stores `attachmentId -> Attachment`
    public fileprivate(set) var attachments: [String: Attachment] = [:]
    
    /// Stores `interactionId -> MaybeUnresolvedQuotedInfo`
    public fileprivate(set) var quoteMap: [Int64: MessageViewModel.MaybeUnresolvedQuotedInfo] = [:]
    
    /// Stores `url -> previews`
    public fileprivate(set) var linkPreviews: [String: Set<LinkPreview>] = [:]
    
    /// Stores `interactionId -> reactions`
    public fileprivate(set) var reactions: [Int64: [Reaction]] = [:]
    
    /// Stores `blindedId -> unblindedId`
    public fileprivate(set) var unblindedIdMap: [String: String] = [:]
    
    // MARK: - UI State
    
    /// Stores `threadIds` for conversations with incoming typing
    public fileprivate(set) var incomingTyping: Set<String> = []
    
    // MARK: - Initialization
    
    public init(userSessionId: SessionId, context: Context) {
        self.userSessionId = userSessionId
        self.context = context
    }
}

// MARK: - Read Operations

public extension ConversationDataCache {
    func profile(for id: String) -> Profile? { profiles[id] }
    func thread(for id: String) -> SessionThread? { threads[id] }
    func contact(for threadId: String) -> Contact? { contacts[threadId] }
    func group(for threadId: String) -> ClosedGroup? { groups[threadId] }
    func groupInfo(for threadId: String) -> LibSession.GroupInfo? { groupInfo[threadId] }
    func groupMembers(for threadId: String) -> [GroupMember] { (groupMembers[threadId] ?? []) }
    func community(for threadId: String) -> OpenGroup? { communities[threadId] }
    func communityCapabilities(for server: String) -> Set<Capability.Variant> {
        (communityCapabilities[server] ?? [])
    }
    func communityModAdminIds(for threadId: String) -> Set<String> { (communityModAdminIds[threadId] ?? []) }
    func isUserModeratorOrAdmin(in threadId: String) -> Bool { (userModeratorOrAdmin[threadId] ?? false) }
    func disappearingMessageConfiguration(for threadId: String) -> DisappearingMessagesConfiguration? {
        disappearingMessagesConfigurations[threadId]
    }
    func interactionStats(for threadId: String) -> ConversationInfoViewModel.InteractionStats? {
        interactionStats[threadId]
    }
    func lastInteraction(for threadId: String) -> ConversationInfoViewModel.InteractionInfo? {
        lastInteractions[threadId]
    }
    func currentUserSessionIds(for threadId: String) -> Set<String> {
        return (currentUserSessionIds[threadId] ?? [userSessionId.hexString])
    }
    
    func interaction(for id: Int64) -> Interaction? { interactions[id] }
    func attachment(for id: String) -> Attachment? { attachments[id] }
    func attachments(for interactionId: Int64) -> [Attachment] {
        guard let interactionAttachments: Set<InteractionAttachment> = attachmentMap[interactionId] else {
            return []
        }
        
        return interactionAttachments
            .sorted { $0.albumIndex < $1.albumIndex }
            .compactMap { attachments[$0.attachmentId] }
    }
    func interactionAttachments(for interactionId: Int64) -> Set<InteractionAttachment> {
        (attachmentMap[interactionId] ?? [])
    }
    func quoteInfo(for interactionId: Int64) -> MessageViewModel.MaybeUnresolvedQuotedInfo? {
        quoteMap[interactionId]
    }
    func linkPreviews(for url: String) -> Set<LinkPreview> { (linkPreviews[url] ?? []) }
    func reactions(for interactionId: Int64) -> [Reaction] { (reactions[interactionId] ?? []) }
    func unblindedId(for blindedId: String) -> String? { unblindedIdMap[blindedId] }
    func isTyping(in threadId: String) -> Bool { incomingTyping.contains(threadId) }
    
    func displayNameRetriever(for threadId: String, includeSessionIdSuffixWhenInMessageBody: Bool) -> DisplayNameRetriever {
        let currentUserSessionIds: Set<String> = currentUserSessionIds(for: threadId)
        
        return { sessionId, inMessageBody in
            guard !currentUserSessionIds.contains(sessionId) else {
                return "you".localized()
            }
            
            return profile(for: sessionId)?.displayName(
                includeSessionIdSuffix: (includeSessionIdSuffixWhenInMessageBody && inMessageBody)
            )
        }
    }
}

// MARK: - Write Operations

public extension ConversationDataCache {
    mutating func withContext(
        source: Context.Source,
        requireFullRefresh: Bool = false,
        requireAuthMethodFetch: Bool = false,
        requiresMessageRequestCountUpdate: Bool = false,
        requiresInitialUnreadInteractionInfo: Bool = false,
        requireRecentReactionEmojiUpdate: Bool = false
    ) {
        self.context = Context(
            source: source,
            requireFullRefresh: requireFullRefresh,
            requireAuthMethodFetch: requireAuthMethodFetch,
            requiresMessageRequestCountUpdate: requiresMessageRequestCountUpdate,
            requiresInitialUnreadInteractionInfo: requiresInitialUnreadInteractionInfo,
            requireRecentReactionEmojiUpdate: requireRecentReactionEmojiUpdate
        )
    }
    
    mutating func insert(_ profile: Profile) {
        self.profiles[profile.id] = profile
    }
    
    mutating func insert(profiles: [Profile]) {
        profiles.forEach { self.profiles[$0.id] = $0 }
    }
    
    mutating func insert(_ thread: SessionThread) {
        self.threads[thread.id] = thread
    }
    
    mutating func insert(threads: [SessionThread]) {
        threads.forEach { self.threads[$0.id] = $0 }
    }
    
    mutating func insert(_ contact: Contact) {
        self.contacts[contact.id] = contact
    }
    
    mutating func insert(contacts: [Contact]) {
        contacts.forEach { self.contacts[$0.id] = $0 }
    }
    
    mutating func insert(_ group: ClosedGroup) {
        self.groups[group.threadId] = group
    }
    
    mutating func insert(groups: [ClosedGroup]) {
        groups.forEach { self.groups[$0.threadId] = $0 }
    }
    
    mutating func insert(_ groupInfo: LibSession.GroupInfo) {
        self.groupInfo[groupInfo.groupSessionId] = groupInfo
    }
    
    mutating func insert(groupInfo: [LibSession.GroupInfo]) {
        groupInfo.forEach { self.groupInfo[$0.groupSessionId] = $0 }
    }
    
    mutating func insert(groupMembers: [String: [GroupMember]]) {
        self.groupMembers.merge(groupMembers) { _, new in new }
    }
    
    mutating func insert(_ community: OpenGroup) {
        self.communities[community.threadId] = community
    }
    
    mutating func insert(communities: [OpenGroup]) {
        communities.forEach { self.communities[$0.threadId] = $0 }
    }
    
    mutating func insert(communityCapabilities: [String: Set<Capability.Variant>]) {
        self.communityCapabilities.merge(communityCapabilities) { _, new in new }
    }
    
    mutating func insert(communityModAdminIds: [String: Set<String>]) {
        self.communityModAdminIds.merge(communityModAdminIds) { _, new in new }
    }
    
    mutating func insert(isUserModeratorOrAdmin: Bool, in threadId: String) {
        self.userModeratorOrAdmin[threadId] = isUserModeratorOrAdmin
    }
    
    mutating func insert(_ config: DisappearingMessagesConfiguration) {
        self.disappearingMessagesConfigurations[config.threadId] = config
    }
    
    mutating func insert(disappearingMessagesConfigurations configs: [DisappearingMessagesConfiguration]) {
        configs.forEach { self.disappearingMessagesConfigurations[$0.threadId] = $0 }
    }
    
    mutating func insert(_ stats: ConversationInfoViewModel.InteractionStats) {
        self.interactionStats[stats.threadId] = stats
    }
    
    mutating func insert(interactionStats: [ConversationInfoViewModel.InteractionStats]) {
        interactionStats.forEach { self.interactionStats[$0.threadId] = $0 }
    }
    
    mutating func insert(_ lastInteraction: ConversationInfoViewModel.InteractionInfo) {
        self.lastInteractions[lastInteraction.threadId] = lastInteraction
    }
    
    mutating func insert(lastInteractions: [String: ConversationInfoViewModel.InteractionInfo]) {
        self.lastInteractions.merge(lastInteractions) { _, new in new }
    }
    
    mutating func setCurrentUserSessionIds(_ currentUserSessionIds: [String: Set<String>]) {
        self.currentUserSessionIds = currentUserSessionIds
    }
    
    mutating func insert(_ interaction: Interaction) {
        guard let id: Int64 = interaction.id else { return }
        
        self.interactions[id] = interaction
    }
    
    mutating func insert(interactions: [Interaction]) {
        interactions.forEach { interaction in
            guard let id: Int64 = interaction.id else { return }
            
            self.interactions[id] = interaction
        }
    }
    
    mutating func insert(_ attachment: Attachment) {
        self.attachments[attachment.id] = attachment
    }
    
    mutating func insert(attachments: [Attachment]) {
        attachments.forEach { self.attachments[$0.id] = $0 }
    }
    
    mutating func insert(attachmentMap: [Int64: Set<InteractionAttachment>]) {
        self.attachmentMap.merge(attachmentMap) { _, new in new }
        
        /// Remove any empty lists
        attachmentMap.forEach { key, value in
            guard value.isEmpty else { return }
            
            self.attachmentMap.removeValue(forKey: key)
        }
    }
    
    mutating func insert(quoteMap: [Int64: MessageViewModel.MaybeUnresolvedQuotedInfo]) {
        self.quoteMap.merge(quoteMap) { _, new in new }
    }
    
    mutating func insert(linkPreviews: [LinkPreview]) {
        linkPreviews.forEach { preview in
            self.linkPreviews[preview.url, default: []].insert(preview)
        }
    }
    
    mutating func insert(reactions: [Int64: [Reaction]]) {
        let sortedReactions: [Int64: [Reaction]] = reactions.mapValues {
            $0.sorted { lhs, rhs in lhs.sortId < rhs.sortId }
        }
        self.reactions.merge(sortedReactions) { _, new in new }
        
        /// Remove any empty lists
        reactions.forEach { key, value in
            guard value.isEmpty else { return }
            
            self.reactions.removeValue(forKey: key)
        }
    }
    
    mutating func insert(unblindedIdMap: [String: String]) {
        self.unblindedIdMap.merge(unblindedIdMap) { _, new in new }
    }
    
    mutating func setTyping(_ isTyping: Bool, in threadId: String) {
        if isTyping {
            self.incomingTyping.insert(threadId)
        } else {
            self.incomingTyping.remove(threadId)
        }
    }
    
    mutating func remove(threadIds: Set<String>) {
        threadIds.forEach { threadId in
            self.threads.removeValue(forKey: threadId)
            self.contacts.removeValue(forKey: threadId)
            self.groups.removeValue(forKey: threadId)
            self.groupInfo.removeValue(forKey: threadId)
            self.groupMembers.removeValue(forKey: threadId)
            self.communities.removeValue(forKey: threadId)
            self.communityModAdminIds.removeValue(forKey: threadId)
            self.userModeratorOrAdmin.removeValue(forKey: threadId)
            self.disappearingMessagesConfigurations.removeValue(forKey: threadId)
            self.interactionStats.removeValue(forKey: threadId)
            self.incomingTyping.remove(threadId)
            self.lastInteractions.removeValue(forKey: threadId)
            
            let interactions: [Interaction] = Array(self.interactions.values)
            interactions.forEach { interaction in
                guard
                    let interactionId: Int64 = interaction.id,
                    interaction.threadId == threadId
                else { return }
                
                self.interactions.removeValue(forKey: interactionId)
                self.attachmentMap[interactionId]?.forEach { attachments.removeValue(forKey: $0.attachmentId) }
                self.attachmentMap.removeValue(forKey: interactionId)
            }
        }
    }
    
    mutating func remove(interactionIds: Set<Int64>) {
        interactionIds.forEach { id in
            self.interactions.removeValue(forKey: id)
            self.reactions.removeValue(forKey: id)
            self.attachmentMap[id]?.forEach {
                self.attachments.removeValue(forKey: $0.attachmentId)
            }
            self.attachmentMap.removeValue(forKey: id)
        }
    }
    
    mutating func removeAttachmentMap(for interactionId: Int64) {
        self.attachmentMap.removeValue(forKey: interactionId)
    }
}

// MARK: - Convenience

public extension ConversationDataCache {
    func contactDisplayName(for threadId: String) -> String {
        /// We expect a non-nullable string so if it's invalid just return an empty string
        guard
            let thread: SessionThread = thread(for: threadId),
            thread.variant == .contact
        else { return "" }
        
        let profile: Profile = (profile(for: thread.id) ?? Profile.defaultFor(thread.id))
        
        return profile.displayName()
    }
}
