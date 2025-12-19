// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension ObservableKey {
    static let isUsingFullAPNs: ObservableKey = "isUsingFullAPNs"
    
    static func setting(_ key: Setting.BoolKey) -> ObservableKey { ObservableKey(key.rawValue, .setting) }
    static func setting(_ key: Setting.EnumKey) -> ObservableKey { ObservableKey(key.rawValue, .setting) }
    
    static func setting(_ key: KeyValueStore.IntKey) -> ObservableKey { ObservableKey(key.rawValue, .setting) }
    
    static func loadPage(_ screenType: Any.Type) -> ObservableKey {
        ObservableKey("loadPage-\(screenType)", .loadPage)
    }
    
    static func updateSelection(_ screenType: Any.Type, _ id: String) -> ObservableKey {
        ObservableKey("updateSelection-\(screenType)-\(id)", .updateSelection)
    }
    
    static func clearSelection(_ screenType: Any.Type) -> ObservableKey {
        ObservableKey("clearSelection-\(screenType)", .clearSelection)
    }
    
    static func updateScreen(_ screenType: Any.Type) -> ObservableKey {
        ObservableKey("updateScreen-\(screenType)", .updateScreen)
    }
    
    static func typingIndicator(_ threadId: String) -> ObservableKey {
        ObservableKey("typingIndicator-\(threadId)", .typingIndicator)
    }
    
    // MARK: - Contacts
    
    static func profile(_ id: String) -> ObservableKey {
        ObservableKey("profile-\(id)", .profile)
    }
    static func contact(_ id: String) -> ObservableKey {
        ObservableKey("contact-\(id)", .contact)
    }
    
    static let anyContactBlockedStatusChanged: ObservableKey = {
        ObservableKey("anyContactBlockedStatusChanged", .anyContactBlockedStatusChanged)
    }()
    static let anyContactUnblinded: ObservableKey = ObservableKey("anyContactUnblinded", .anyContactUnblinded)
    
    // MARK: - Conversations
    
    static let conversationCreated: ObservableKey = ObservableKey("conversationCreated", .conversationCreated)
    static let anyConversationPinnedPriorityChanged: ObservableKey = {
        ObservableKey("anyConversationPinnedPriorityChanged", .anyConversationPinnedPriorityChanged)
    }()
    
    static func conversationUpdated(_ id: String) -> ObservableKey {
        ObservableKey("conversationUpdated-\(id)", .conversationUpdated)
    }
    static func conversationDeleted(_ id: String) -> ObservableKey {
        ObservableKey("conversationDeleted-\(id)", .conversationDeleted)
    }
    
    // MARK: - Messages
    
    static let anyMessageCreatedInAnyConversation: ObservableKey = "anyMessageCreatedInAnyConversation"
    
    static func messageCreated(threadId: String) -> ObservableKey {
        ObservableKey("messageCreated-\(threadId)", .messageCreated)
    }
    static func messageUpdated(id: Int64?, threadId: String) -> ObservableKey {
        ObservableKey("messageUpdated-\(threadId)-\(id.map { "\($0)" } ?? "NULL")", .messageUpdated)
    }
    static func messageDeleted(id: Int64?, threadId: String) -> ObservableKey {
        ObservableKey("messageDeleted-\(threadId)-\(id.map { "\($0)" } ?? "NULL")", .messageDeleted)
    }
    
    static func attachmentCreated(messageId: Int64?) -> ObservableKey {
        ObservableKey("attachmentUpdated-\(messageId.map { "\($0)" } ?? "NULL")", .attachmentCreated)
    }
    static func attachmentUpdated(id: String, messageId: Int64?) -> ObservableKey {
        ObservableKey("attachmentUpdated-\(id)-\(messageId.map { "\($0)" } ?? "NULL")", .attachmentUpdated)
    }
    static func attachmentDeleted(id: String, messageId: Int64?) -> ObservableKey {
        ObservableKey("attachmentDeleted-\(id)-\(messageId.map { "\($0)" } ?? "NULL")", .attachmentDeleted)
    }
    
    static let recentReactionsUpdated: ObservableKey = "recentReactionsUpdated"
    static func reactionsChanged(messageId: Int64) -> ObservableKey {
        ObservableKey("reactionsChanged-\(messageId)", .reactionsChanged)
    }
    
    // MARK: - Message Requests
    
    static let messageRequestAccepted: ObservableKey = "messageRequestAccepted"
    static let messageRequestDeleted: ObservableKey = "messageRequestDeleted"
    static let messageRequestMessageRead: ObservableKey = "messageRequestMessageRead"
    static let messageRequestUnreadMessageReceived: ObservableKey = "messageRequestUnreadMessageReceived"
    
    // MARK: - Groups
    
    static func groupInfo(groupId: String) -> ObservableKey {
        ObservableKey("groupInfo-\(groupId)", .groupInfo)
    }
    
    static func groupMemberCreated(threadId: String) -> ObservableKey {
        ObservableKey("groupMemberCreated-\(threadId)", .groupMemberCreated)
    }
    static func groupMemberUpdated(profileId: String, threadId: String) -> ObservableKey {
        ObservableKey("groupMemberUpdated-\(threadId)-\(profileId)", .groupMemberUpdated)
    }
    
    static func anyGroupMemberDeleted(threadId: String) -> ObservableKey {
        ObservableKey("anyGroupMemberDeleted-\(threadId)", .anyGroupMemberDeleted)
    }
    static func groupMemberDeleted(profileId: String, threadId: String) -> ObservableKey {
        ObservableKey("groupMemberDeleted-\(threadId)-\(profileId)", .groupMemberDeleted)
    }
}

public extension GenericObservableKey {
    static let setting: GenericObservableKey = "setting"
    static let loadPage: GenericObservableKey = "loadPage"
    static let updateSelection: GenericObservableKey = "updateSelection"
    static let clearSelection: GenericObservableKey = "clearSelection"
    static let updateScreen: GenericObservableKey = "updateScreen"
    static let typingIndicator: GenericObservableKey = "typingIndicator"
    static let profile: GenericObservableKey = "profile"
    static let contact: GenericObservableKey = "contact"
    static let anyContactBlockedStatusChanged: GenericObservableKey = "anyContactBlockedStatusChanged"
    static let anyContactUnblinded: GenericObservableKey = "anyContactUnblinded"
    
    static let conversationCreated: GenericObservableKey = "conversationCreated"
    static let anyConversationPinnedPriorityChanged: GenericObservableKey = "anyConversationPinnedPriorityChanged"
    static let conversationUpdated: GenericObservableKey = "conversationUpdated"
    static let conversationDeleted: GenericObservableKey = "conversationDeleted"
    static let messageCreated: GenericObservableKey = "messageCreated"
    static let messageUpdated: GenericObservableKey = "messageUpdated"
    static let messageDeleted: GenericObservableKey = "messageDeleted"
    static let attachmentCreated: GenericObservableKey = "attachmentCreated"
    static let attachmentUpdated: GenericObservableKey = "attachmentUpdated"
    static let attachmentDeleted: GenericObservableKey = "attachmentDeleted"
    static let reactionsChanged: GenericObservableKey = "reactionsChanged"
    
    static let groupInfo: GenericObservableKey = "groupInfo"
    static let groupMemberCreated: GenericObservableKey = "groupMemberCreated"
    static let groupMemberUpdated: GenericObservableKey = "groupMemberUpdated"
    static let anyGroupMemberDeleted: GenericObservableKey = "anyGroupMemberDeleted"
    static let groupMemberDeleted: GenericObservableKey = "groupMemberDeleted"
}

// MARK: - Event Payloads - General

public enum CRUDEvent<T> {
    case created
    case updated(T)
    case deleted
    
    var change: T? {
        switch self {
            case .updated(let value): return value
            case .created, .deleted: return nil
        }
    }
}

public struct LoadPageEvent: Hashable {
    public let target: Target
    
    public enum Target: Hashable {
        case initial
        case initialPageAround(AnyHashable)
        case previousPage(Int)
        case nextPage(Int)
        case jumpTo(AnyHashable, Int)
    }
    
    public static var initial: LoadPageEvent { LoadPageEvent(target: .initial) }
    
    public static func initialPageAround<ID: Hashable>(id: ID) -> LoadPageEvent {
        LoadPageEvent(target: .initialPageAround(id))
    }
    
    public static func previousPage(firstIndex: Int) -> LoadPageEvent {
        LoadPageEvent(target: .previousPage(firstIndex))
    }
    
    public static func nextPage(lastIndex: Int) -> LoadPageEvent {
        LoadPageEvent(target: .nextPage(lastIndex))
    }
    
    public static func jumpTo<ID: Hashable>(id: ID, padding: Int) -> LoadPageEvent {
        LoadPageEvent(target: .jumpTo(id, padding))
    }
}

public struct UpdateSelectionEvent: Hashable {
    public let id: String
    public let isSelected: Bool
    
    public init(id: String, isSelected: Bool) {
        self.id = id
        self.isSelected = isSelected
    }
}

public struct TypingIndicatorEvent: Hashable {
    public let threadId: String
    public let change: Change
    
    public enum Change: Hashable {
        case started
        case stopped
    }
}

// MARK: - Event Payloads - Contacts

public struct ProfileEvent: Hashable {
    public let id: String
    public let change: Change
    
    public enum Change: Hashable {
        case name(String)
        case nickname(String?)
        case displayPictureUrl(String?)
        case proStatus(
            isPro: Bool,
            profileFeatures: SessionPro.ProfileFeatures,
            expiryUnixTimestampMs: UInt64,
            genIndexHashHex: String?
        )
    }
}

public extension ObservingDatabase {
    func addProfileEvent(id: String, change: ProfileEvent.Change) {
        self.addEvent(ObservedEvent(key: .profile(id), value: ProfileEvent(id: id, change: change)))
    }
}

public struct ContactEvent: Hashable {
    public let id: String
    public let change: Change
    
    public enum Change: Hashable {
        case isTrusted(Bool)
        case isApproved(Bool)
        case isBlocked(Bool)
        case didApproveMe(Bool)
        case unblinded(blindedId: String, unblindedId: String)
    }
}

public extension ObservingDatabase {
    func addContactEvent(id: String, change: ContactEvent.Change) {
        let event: ContactEvent = ContactEvent(id: id, change: change)
        
        /// When certain contact events occur some screens want to respond to them regardless of whether the current observation
        /// window includes the record, so we need to emit generic "any" events for these cases
        switch change {
            case .isBlocked: addEvent(ObservedEvent(key: .anyContactBlockedStatusChanged, value: event))
            case .unblinded: addEvent(ObservedEvent(key: .anyContactUnblinded, value: event))
            default: break
        }
        
        addEvent(ObservedEvent(key: .contact(id), value: event))
    }
}

// MARK: - Event Payloads - Conversations

public struct ConversationEvent: Hashable {
    public let id: String
    public let variant: SessionThread.Variant
    public let change: Change?
    
    public enum Change: Hashable {
        case displayName(String)
        case description(String?)
        case displayPictureUrl(String?)
        case pinnedPriority(Int32)
        case shouldBeVisible(Bool)
        case mutedUntilTimestamp(TimeInterval?)
        case onlyNotifyForMentions(Bool)
        case markedAsUnread(Bool)
        case draft(String?)
        case disappearingMessageConfiguration(DisappearingMessagesConfiguration?)
        case unreadCount
    }
}

public extension ObservingDatabase {
    func addConversationEvent(id: String, variant: SessionThread.Variant, type: CRUDEvent<ConversationEvent.Change>) {
        let event: ConversationEvent = ConversationEvent(id: id, variant: variant, change: type.change)
        
        switch type {
            case .created: addEvent(ObservedEvent(key: .conversationCreated, value: event))
            case .updated:
                addEvent(ObservedEvent(key: .conversationUpdated(id), value: event))
                if case .pinnedPriority = type.change {
                    addEvent(ObservedEvent(key: .anyConversationPinnedPriorityChanged, value: event))
                }
            case .deleted: addEvent(ObservedEvent(key: .conversationDeleted(id), value: event))
        }
    }
}

// MARK: - Event Payloads - Messages

public struct MessageEvent: Hashable {
    public let id: Int64?
    public let threadId: String
    public let change: Change?
    
    public enum Change: Hashable {
        case wasRead(Bool)
        case state(Interaction.State)
        case recipientReadTimestampMs(Int64)
        case markedAsDeleted
        case expirationTimerStarted(TimeInterval, Double)
    }
}

public extension ObservingDatabase {
    func addMessageEvent(id: Int64?, threadId: String, type: CRUDEvent<MessageEvent.Change>) {
        let event: MessageEvent = MessageEvent(id: id, threadId: threadId, change: type.change)
        
        switch type {
            case .created:
                /// When a message is created we need to emit both a thread-specific event and a generic event as the home screen
                /// will only observe thread-specific message events for the currently loaded pages (and receiving a message would
                /// result in a conversation that might be off the screen being moved up into the loaded page range)
                addEvent(ObservedEvent(key: .anyMessageCreatedInAnyConversation, value: event))
                addEvent(ObservedEvent(key: .messageCreated(threadId: threadId), value: event))
                
            case .updated: addEvent(ObservedEvent(key: .messageUpdated(id: id, threadId: threadId), value: event))
            case .deleted: addEvent(ObservedEvent(key: .messageDeleted(id: id, threadId: threadId), value: event))
        }
    }
}

public struct AttachmentEvent: Hashable {
    public let id: String
    public let messageId: Int64?
    public let change: Change?
    
    public enum Change: Hashable {
        case state(Attachment.State)
    }
}

public extension ObservingDatabase {
    func addAttachmentEvent(id: String, messageId msgId: Int64?, type: CRUDEvent<AttachmentEvent.Change>) {
        let event: AttachmentEvent = AttachmentEvent(id: id, messageId: msgId, change: type.change)
        
        switch type {
            case .created: addEvent(ObservedEvent(key: .attachmentCreated(messageId: msgId), value: event))
            case .updated: addEvent(ObservedEvent(key: .attachmentUpdated(id: id, messageId: msgId), value: event))
            case .deleted: addEvent(ObservedEvent(key: .attachmentDeleted(id: id, messageId: msgId), value: event))
        }
    }
}

public struct ReactionEvent: Hashable {
    public let id: Int64
    public let messageId: Int64
    public let change: Change
    
    public enum Change: Hashable {
        case added(String)
        case removed(String)
    }
}

public extension ObservingDatabase {
    func addReactionEvent(id: Int64, messageId: Int64, change: ReactionEvent.Change) {
        let event: ReactionEvent = ReactionEvent(id: id, messageId: messageId, change: change)
        
        addEvent(ObservedEvent(key: .reactionsChanged(messageId: messageId), value: event))
    }
}

public struct GroupMemberEvent: Hashable {
    public let profileId: String
    public let threadId: String
    public let change: Change?
    
    public enum Change: Hashable {
        case role(role: GroupMember.Role, status: GroupMember.RoleStatus)
    }
}

public extension ObservingDatabase {
    func addGroupMemberEvent(profileId: String, threadId: String, type: CRUDEvent<GroupMemberEvent.Change>) {
        let event: GroupMemberEvent = GroupMemberEvent(profileId: profileId, threadId: threadId, change: type.change)
        
        switch type {
            case .created: addEvent(ObservedEvent(key: .groupMemberCreated(threadId: threadId), value: event))
            case .updated: addEvent(ObservedEvent(key: .groupMemberUpdated(profileId: profileId, threadId: threadId), value: event))
            case .deleted:
                /// When a group member is deleted we need to emit both a profile+thread-specific event and a thread-specific event
                /// as the message list screen will only observe the thread-specific one to update user count metadata
                addEvent(ObservedEvent(key: .anyGroupMemberDeleted(threadId: threadId), value: event))
                addEvent(ObservedEvent(key: .groupMemberDeleted(profileId: profileId, threadId: threadId), value: event))
        }
    }
}
