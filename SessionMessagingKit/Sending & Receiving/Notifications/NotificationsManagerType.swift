// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUIKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let notificationsManager: SingletonConfig<NotificationsManagerType> = Dependencies.create(
        identifier: "notificationsManager",
        createInstance: { dependencies in NoopNotificationsManager(using: dependencies) }
    )
}

// MARK: - NotificationsManagerType

public protocol NotificationsManagerType {
    var dependencies: Dependencies { get }
    
    init(using dependencies: Dependencies)
    
    func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?)
    func registerNotificationSettings() -> AnyPublisher<Void, Never>
    
    func notificationUserInfo(threadId: String, threadVariant: SessionThread.Variant) -> [String: Any]
    func notificationShouldPlaySound(applicationState: UIApplication.State) -> Bool
    
    func notifyForFailedSend(_ db: Database, in thread: SessionThread, applicationState: UIApplication.State)
    func addNotificationRequest(
        content: NotificationContent,
        notificationSettings: Preferences.NotificationSettings
    )
    
    func cancelNotifications(identifiers: [String])
    func clearAllNotifications()
}

public extension NotificationsManagerType {
    func ensureWeShouldShowNotification(
        message: Message,
        threadId: String,
        threadVariant: SessionThread.Variant,
        interactionVariant: Interaction.Variant?,
        isMessageRequest: Bool,
        notificationSettings: Preferences.NotificationSettings,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?,
        currentUserSessionIds: Set<String>,
        shouldShowForMessageRequest: () -> Bool,
        using dependencies: Dependencies
    ) throws {
        guard let sender: String = message.sender else { throw MessageReceiverError.invalidSender }
        
        /// Don't show notifications for the `Note to Self` thread or messages sent from the current user
        guard !currentUserSessionIds.contains(threadId) && !currentUserSessionIds.contains(sender) else {
            throw MessageReceiverError.selfSend
        }
        
        /// Ensure that the thread isn't muted
        guard
            notificationSettings.mode != .none &&
            dependencies.dateNow.timeIntervalSince1970 > (notificationSettings.mutedUntil ?? 0)
        else { throw MessageReceiverError.ignorableMessage }
        
        switch message {
            /// For a `VisibleMessage` we should only notify if the notification mode is `all` or if `mentionsOnly` and the
            /// user was actually mentioned
            case let visibleMessage as VisibleMessage:
                guard interactionVariant == .standardIncoming else { throw MessageReceiverError.ignorableMessage }
                guard
                    notificationSettings.mode == .all || (
                        notificationSettings.mode == .mentionsOnly &&
                        Interaction.isUserMentioned(
                            publicKeysToCheck: currentUserSessionIds,
                            body: visibleMessage.text,
                            quoteAuthorId: visibleMessage.quote?.authorId
                        )
                    )
                else { throw MessageReceiverError.ignorableMessage }
                
                /// If the message is a reaction then we only want to show notifications for `contact` conversations
                if visibleMessage.reaction != nil {
                    switch threadVariant {
                        case .contact: break
                        case .legacyGroup, .group, .community: throw MessageReceiverError.ignorableMessage
                    }
                }
                break
            
            /// Calls are only supported in `contact` conversations and we only want to notify for missed calls
            case let callMessage as CallMessage:
                guard threadVariant == .contact else { throw MessageReceiverError.invalidMessage }
                guard case .preOffer = callMessage.kind else { throw MessageReceiverError.ignorableMessage }
                
                switch callMessage.state {
                    case .missed, .permissionDenied, .permissionDeniedMicrophone: break
                    default: throw MessageReceiverError.ignorableMessage
                }
                
                /// We need additional dedupe logic if the message is a `CallMessage` as multiple messages can
                /// related to the same call
                try MessageDeduplication.ensureCallMessageIsNotADuplicate(
                    threadId: threadId,
                    callMessage: callMessage,
                    using: dependencies
                )
            
            /// Group invitations and promotions may show notifications in some cases
            case is GroupUpdateInviteMessage, is GroupUpdatePromoteMessage: break
            
            /// No other messages should have notifications
            default: throw MessageReceiverError.ignorableMessage
        }
        
        /// Ensure the sender isn't blocked (this should be checked when parsing the message but we should also check here in case
        /// that logic ever changes)
        guard
            !dependencies.mutate(cache: .libSession, { cache in
                cache.isContactBlocked(contactId: sender)
            })
        else { throw MessageReceiverError.senderBlocked }
        
        /// Ensure the message hasn't already been maked as read (don't want to show notification in that case)
        guard
            !dependencies.mutate(cache: .libSession, { cache in
                cache.timestampAlreadyRead(
                    threadId: threadId,
                    threadVariant: threadVariant,
                    timestampMs: (message.sentTimestampMs.map { Int64($0) } ?? 0),  /// Default to unread
                    openGroupUrlInfo: openGroupUrlInfo
                )
            })
        else { throw MessageReceiverError.ignorableMessage }
        
        /// If the thread is a message request then we only want to show a notification for the first message
        switch (threadVariant, isMessageRequest) {
            case (.community, _), (.legacyGroup, _), (.contact, false), (.group, false): break
            case (.contact, true), (.group, true):
                guard shouldShowForMessageRequest() else { throw MessageReceiverError.ignorableMessageRequestMessage }
                break
        }
        
        /// If we made it here then we should show the notification
    }
    
    func notificationTitle(
        message: Message,
        threadId: String,
        threadVariant: SessionThread.Variant,
        isMessageRequest: Bool,
        notificationSettings: Preferences.NotificationSettings,
        displayNameRetriever: (String) -> String?,
        using dependencies: Dependencies
    ) throws -> String {
        switch (notificationSettings.previewType, message.sender, isMessageRequest, threadVariant) {
            /// If it's a message request or shouldn't have a title then use something generic
            case (.noNameNoPreview, _, _, _), (_, _, true, _), (_, .none, _, _):
                return Constants.app_name
                
            case (.nameNoPreview, .some(let sender), _, .contact), (.nameAndPreview, .some(let sender), _, .contact):
                return displayNameRetriever(sender)
                    .defaulting(to: Profile.truncated(id: sender, threadVariant: threadVariant))
                
            case (.nameNoPreview, .some(let sender), _, .group), (.nameAndPreview, .some(let sender), _, .group):
                let groupId: SessionId = SessionId(.group, hex: threadId)
                let senderName: String = displayNameRetriever(sender)
                    .defaulting(to: Profile.truncated(id: sender, threadVariant: threadVariant))
                let groupName: String = dependencies.mutate(cache: .libSession) { cache in
                    cache.groupName(groupSessionId: groupId)
                }
                .defaulting(to: "groupUnknown".localized())
                
                return "notificationsIosGroup"
                    .put(key: "name", value: senderName)
                    .put(key: "conversation_name", value: groupName)
                    .localized()
                
            default: throw MessageReceiverError.ignorableMessage
        }
    }
    
    func notificationBody(
        message: Message,
        threadVariant: SessionThread.Variant,
        isMessageRequest: Bool,
        notificationSettings: Preferences.NotificationSettings,
        interactionVariant: Interaction.Variant?,
        attachmentDescriptionInfo: [Attachment.DescriptionInfo]?,
        currentUserSessionIds: Set<String>,
        displayNameRetriever: (String) -> String?,
        using dependencies: Dependencies
    ) -> String {
        /// If it's a message request  then use something generic
        guard !isMessageRequest else { return "messageRequestsNew".localized() }
        
        /// If it shouldn't have the content or has no sender then use something generic
        guard
            let sender: String = message.sender,
            notificationSettings.previewType == .nameAndPreview
        else {
            return "messageNewYouveGot"
                .putNumber(1)
                .localized()
        }
        
        switch message {
            case let visibleMessage as VisibleMessage where visibleMessage.reaction != nil:
                return "emojiReactsNotification"
                    .put(key: "emoji", value: (visibleMessage.reaction?.emoji ?? ""))
                    .localized()
                
            case let visibleMessage as VisibleMessage:
                return (interactionVariant
                    .map { variant -> String in
                        Interaction.previewText(
                            variant: variant,
                            body: visibleMessage.text,
                            authorDisplayName: displayNameRetriever(sender)
                                .defaulting(to: Profile.truncated(id: sender, threadVariant: threadVariant)),
                            attachmentDescriptionInfo: attachmentDescriptionInfo?.first,
                            attachmentCount: (attachmentDescriptionInfo?.count ?? 0),
                            isOpenGroupInvitation: (visibleMessage.openGroupInvitation != nil),
                            using: dependencies
                        )
                    }?
                    .filteredForDisplay
                    .filteredForNotification
                    .nullIfEmpty?
                    .replacingMentions(
                        currentUserSessionIds: currentUserSessionIds,
                        displayNameRetriever: displayNameRetriever
                    ))
                    .defaulting(to: "messageNewYouveGot"
                        .putNumber(1)
                        .localized()
                    )
                
            case let callMessage as CallMessage where callMessage.state == .permissionDenied:
                let senderName: String = displayNameRetriever(sender)
                    .defaulting(to: Profile.truncated(id: sender, threadVariant: threadVariant))
                
                return "callsYouMissedCallPermissions"
                    .put(key: "name", value: senderName)
                    .localizedDeformatted()
                
            case is CallMessage:
                let senderName: String = displayNameRetriever(sender)
                    .defaulting(to: Profile.truncated(id: sender, threadVariant: threadVariant))
                
                return "callsMissedCallFrom"
                    .put(key: "name", value: senderName)
                    .localizedDeformatted()
                
            /// Fallback to soemthing generic
            default:
                return "messageNewYouveGot"
                    .putNumber(1)
                    .localized()
        }
    }
    
    func notifyUser(
        message: Message,
        threadId: String,
        threadVariant: SessionThread.Variant,
        interactionId: Int64,
        interactionVariant: Interaction.Variant?,
        attachmentDescriptionInfo: [Attachment.DescriptionInfo]?,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?,
        applicationState: UIApplication.State,
        currentUserSessionIds: Set<String>,
        displayNameRetriever: (String) -> String?,
        shouldShowForMessageRequest: () -> Bool
    ) throws {
        let targetConfig: ConfigDump.Variant = (threadVariant == .contact ? .contacts : .userGroups)
        let isMessageRequest: Bool = dependencies.mutate(cache: .libSession) { cache in
            cache.isMessageRequest(
                threadId: threadId,
                threadVariant: threadVariant
            )
        }
        let notificationSettings: Preferences.NotificationSettings = dependencies.mutate(cache: .libSession) { cache in
            cache.notificationSettings(
                threadId: threadId,
                threadVariant: threadVariant,
                openGroupUrlInfo: openGroupUrlInfo
            )
        }
        
        /// Ensure we should be showing a notification for the thread
        try ensureWeShouldShowNotification(
            message: message,
            threadId: threadId,
            threadVariant: threadVariant,
            interactionVariant: interactionVariant,
            isMessageRequest: isMessageRequest,
            notificationSettings: notificationSettings,
            openGroupUrlInfo: openGroupUrlInfo,
            currentUserSessionIds: currentUserSessionIds,
            shouldShowForMessageRequest: {
                !dependencies[singleton: .extensionHelper]
                    .hasAtLeastOneDedupeRecord(threadId: threadId)
            },
            using: dependencies
        )
        
        /// Actually add the notification
        addNotificationRequest(
            content: NotificationContent(
                threadId: threadId,
                threadVariant: threadVariant,
                identifier: {
                    switch (message as? VisibleMessage)?.reaction {
                        case .some: return UUID().uuidString
                        default:
                            return Interaction.notificationIdentifier(
                                for: interactionId,
                                threadId: threadId,
                                shouldGroupMessagesForThread: (threadVariant == .community)
                            )
                    }
                }(),
                category: .incomingMessage,
                title: try notificationTitle(
                    message: message,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    isMessageRequest: isMessageRequest,
                    notificationSettings: notificationSettings,
                    displayNameRetriever: displayNameRetriever,
                    using: dependencies
                ),
                body: notificationBody(
                    message: message,
                    threadVariant: threadVariant,
                    isMessageRequest: isMessageRequest,
                    notificationSettings: notificationSettings,
                    interactionVariant: interactionVariant,
                    attachmentDescriptionInfo: attachmentDescriptionInfo,
                    currentUserSessionIds: currentUserSessionIds,
                    displayNameRetriever: displayNameRetriever,
                    using: dependencies
                ),
                // TODO: [Database Relocation] Need to figure out how to manage the unread count...
                /// Update the app badge in case the unread count changed
        //        if let unreadCount: Int = try? Interaction.fetchAppBadgeUnreadCount(db, using: dependencies) {
        //            notificationContent.badge = NSNumber(value: unreadCount)
        //        }
    //            badge: ,
                sound: notificationSettings.sound,
                userInfo: notificationUserInfo(threadId: threadId, threadVariant: threadVariant),
                applicationState: applicationState
            ),
            notificationSettings: notificationSettings
        )
    }
}

// MARK: - NoopNotificationsManager

public struct NoopNotificationsManager: NotificationsManagerType {
    public let dependencies: Dependencies
    
    public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    public func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {}
    
    public func registerNotificationSettings() -> AnyPublisher<Void, Never> {
        return Just(()).eraseToAnyPublisher()
    }
    
    public func notificationUserInfo(threadId: String, threadVariant: SessionThread.Variant) -> [String: Any] {
        return [:]
    }
    
    public func notificationShouldPlaySound(applicationState: UIApplication.State) -> Bool {
        return false
    }
    
    public func notifyForFailedSend(_ db: Database, in thread: SessionThread, applicationState: UIApplication.State) {}
    
    public func addNotificationRequest(
        content: NotificationContent,
        notificationSettings: Preferences.NotificationSettings
    ) {}
    public func cancelNotifications(identifiers: [String]) {}
    public func clearAllNotifications() {}
}

// MARK: - Notifications

public enum Notifications {
    /// Delay notification of incoming messages when we want to group them (eg. during background polling) to avoid
    /// firing too many notifications at the same time
    public static let delayForGroupedNotifications: TimeInterval = 5
}
