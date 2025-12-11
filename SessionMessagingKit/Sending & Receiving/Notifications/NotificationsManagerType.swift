// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
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
    func registerSystemNotificationSettings() -> AnyPublisher<Void, Never>
    
    func settings(threadId: String?, threadVariant: SessionThread.Variant) -> Preferences.NotificationSettings
    func updateSettings(
        threadId: String,
        threadVariant: SessionThread.Variant,
        mentionsOnly: Bool,
        mutedUntil: TimeInterval?
    )
    func notificationUserInfo(threadId: String, threadVariant: SessionThread.Variant) -> [String: Any]
    func notificationShouldPlaySound(applicationState: UIApplication.State) -> Bool
    
    func notifyForFailedSend(
        threadId: String,
        threadVariant: SessionThread.Variant,
        applicationState: UIApplication.State
    )
    func scheduleSessionNetworkPageLocalNotifcation(force: Bool)
    func addNotificationRequest(
        content: NotificationContent,
        notificationSettings: Preferences.NotificationSettings,
        extensionBaseUnreadCount: Int?
    )
    
    func cancelNotifications(identifiers: [String])
    func clearAllNotifications()
}

public extension NotificationsManagerType {
    func settings(threadVariant: SessionThread.Variant) -> Preferences.NotificationSettings {
        return settings(threadId: nil, threadVariant: threadVariant)
    }
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
        guard let sender: String = message.sender else { throw MessageError.invalidSender }
        
        /// Don't show notifications for the `Note to Self` thread or messages sent from the current user
        guard !currentUserSessionIds.contains(threadId) && !currentUserSessionIds.contains(sender) else {
            throw MessageError.selfSend
        }
        
        /// Ensure that the thread isn't muted
        guard dependencies.dateNow.timeIntervalSince1970 > (notificationSettings.mutedUntil ?? 0) else {
            throw MessageError.ignorableMessage
        }
        
        switch message {
            /// For a `VisibleMessage` we should only notify if the notification mode is `all` or if `mentionsOnly` and the
            /// user was actually mentioned
            case let visibleMessage as VisibleMessage:
                guard interactionVariant == .standardIncoming else { throw MessageError.ignorableMessage }
                guard
                    !notificationSettings.mentionsOnly ||
                    Interaction.isUserMentioned(
                        publicKeysToCheck: currentUserSessionIds,
                        body: visibleMessage.text,
                        quoteAuthorId: visibleMessage.quote?.authorId
                    )
                else { throw MessageError.ignorableMessage }
                
                /// If the message is a reaction then we only want to show notifications for `contact` conversations, any only if the
                /// reaction isn't added to a message sent by the reactor
                if visibleMessage.reaction != nil {
                    switch threadVariant {
                        case .contact:
                            guard visibleMessage.reaction?.publicKey != sender else {
                                throw MessageError.ignorableMessage
                            }
                            break
                            
                        case .legacyGroup, .group, .community: throw MessageError.ignorableMessage
                    }
                }
                break
            
            /// Calls are only supported in `contact` conversations and we only want to notify for missed calls
            case let callMessage as CallMessage:
                guard threadVariant == .contact else {
                    throw MessageError.invalidMessage("Calls are only supported in 1-to-1 conversations")
                }
                guard case .preOffer = callMessage.kind else { throw MessageError.ignorableMessage }
                
                switch callMessage.state {
                    case .missed, .permissionDenied, .permissionDeniedMicrophone: break
                    default: throw MessageError.ignorableMessage
                }
            
            /// Group invitations and promotions may show notifications in some cases
            case is GroupUpdateInviteMessage, is GroupUpdatePromoteMessage: break
            
            /// No other messages should have notifications
            default: throw MessageError.ignorableMessage
        }
        
        /// Ensure the sender isn't blocked (this should be checked when parsing the message but we should also check here in case
        /// that logic ever changes)
        guard
            dependencies.mutate(cache: .libSession, { cache in
                !cache.isContactBlocked(contactId: sender)
            })
        else { throw MessageError.senderBlocked }
        
        /// Ensure the message hasn't already been maked as read (don't want to show notification in that case)
        guard
            dependencies.mutate(cache: .libSession, { cache in
                !cache.timestampAlreadyRead(
                    threadId: threadId,
                    threadVariant: threadVariant,
                    timestampMs: (message.sentTimestampMs.map { UInt64($0) } ?? 0),  /// Default to unread
                    openGroupUrlInfo: openGroupUrlInfo
                )
            })
        else { throw MessageError.ignorableMessage }
        
        /// If the thread is a message request then we only want to show a notification for the first message
        switch (threadVariant, isMessageRequest) {
            case (.community, _), (.legacyGroup, _), (.contact, false), (.group, false): break
            case (.contact, true), (.group, true):
                guard shouldShowForMessageRequest() else {
                    throw MessageError.ignorableMessageRequestMessage
                }
                break
        }
        
        /// If we made it here then we should show the notification
    }
    
    func notificationTitle(
        cat: Log.Category,
        message: Message,
        threadId: String,
        threadVariant: SessionThread.Variant,
        isMessageRequest: Bool,
        notificationSettings: Preferences.NotificationSettings,
        displayNameRetriever: DisplayNameRetriever,
        groupNameRetriever: (String, SessionThread.Variant) -> String?,
        using dependencies: Dependencies
    ) throws -> String {
        switch (notificationSettings.previewType, message.sender, isMessageRequest, threadVariant) {
            case (.noNameNoPreview, _, _, _):
                Log.info(cat, "Notification content disabled, using generic title.")
                return Constants.app_name
                
            case (_, .none, _, _):
                Log.info(cat, "Sender missing, using generic title.")
                return Constants.app_name
            
            case (_, _, true, _):
                Log.info(cat, "Notification is message request, using generic title.")
                return Constants.app_name
                
            case (.nameNoPreview, .some(let sender), _, .contact), (.nameAndPreview, .some(let sender), _, .contact):
                return displayNameRetriever(sender, false)
                    .defaulting(to: sender.truncated())
                
            case (.nameNoPreview, .some(let sender), _, .group), (.nameAndPreview, .some(let sender), _, .group),
                (.nameNoPreview, .some(let sender), _, .community), (.nameAndPreview, .some(let sender), _, .community):
                let senderName: String = displayNameRetriever(sender, false)
                    .defaulting(to: sender.truncated())
                let groupName: String = groupNameRetriever(threadId, threadVariant)
                    .defaulting(to: "groupUnknown".localized())
                
                return "notificationsIosGroup"
                    .put(key: "name", value: senderName)
                    .put(key: "conversation_name", value: groupName)
                    .localized()
                
            case (_, _, _, .legacyGroup): throw MessageError.ignorableMessage
        }
    }
    
    func notificationBody(
        cat: Log.Category,
        message: Message,
        threadVariant: SessionThread.Variant,
        isMessageRequest: Bool,
        notificationSettings: Preferences.NotificationSettings,
        interactionVariant: Interaction.Variant?,
        attachmentDescriptionInfo: [Attachment.DescriptionInfo]?,
        currentUserSessionIds: Set<String>,
        displayNameRetriever: DisplayNameRetriever,
        using dependencies: Dependencies
    ) -> String {
        /// If it's a message request  then use something generic
        guard !isMessageRequest else { return "messageRequestsNew".localized() }
        
        /// If it shouldn't have the content or has no sender then use something generic
        guard
            let sender: String = message.sender,
            notificationSettings.previewType == .nameAndPreview
        else {
            Log.info(cat, "Notification content disabled, using generic body.")
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
                let bodyText: String? = (interactionVariant
                    .map { variant -> String in
                        Interaction.previewText(
                            variant: variant,
                            body: visibleMessage.text,
                            authorDisplayName: displayNameRetriever(sender, true)
                                .defaulting(to: sender.truncated()),
                            attachmentDescriptionInfo: attachmentDescriptionInfo?.first,
                            attachmentCount: (attachmentDescriptionInfo?.count ?? 0),
                            isOpenGroupInvitation: (visibleMessage.openGroupInvitation != nil)
                        )
                    }?
                    .filteredForDisplay
                    .nullIfEmpty?
                    .replacingMentions(
                        currentUserSessionIds: currentUserSessionIds,
                        displayNameRetriever: displayNameRetriever
                    ))
                
                switch bodyText {
                    case .some(let result): return result
                    case .none:
                        Log.warn(cat, "Failed to process body for visible message (variant: \(interactionVariant.map { "\($0)" } ?? "NULL")), using generic body.")
                        return "messageNewYouveGot"
                            .putNumber(1)
                            .localized()
                }
                
            case let callMessage as CallMessage where callMessage.state == .permissionDenied:
                let senderName: String = (displayNameRetriever(sender, false) ?? sender.truncated())
                
                return "callsYouMissedCallPermissions"
                    .put(key: "name", value: senderName)
                    .localizedDeformatted()
            
            case is CallMessage:
                let senderName: String = (displayNameRetriever(sender, false) ?? sender.truncated())
                
                return "callsMissedCallFrom"
                    .put(key: "name", value: senderName)
                    .localizedDeformatted()
                
            case let inviteMessage as GroupUpdateInviteMessage:
                let senderName: String = (displayNameRetriever(sender, false) ?? sender.truncated())
                let bodyText: String? = ClosedGroup.MessageInfo
                    .invited(senderName, inviteMessage.groupName)
                    .previewText
                    .deformatted()
                
                switch bodyText {
                    case .some(let result): return result
                    case .none:
                        Log.warn(cat, "Failed to process body for group invite message, using generic body.")
                        return "messageNewYouveGot"
                            .putNumber(1)
                            .localized()
                }
                
            case let promotionMessage as GroupUpdatePromoteMessage:
                let senderName: String = (displayNameRetriever(sender, false) ?? sender.truncated())
                let bodyText: String? = ClosedGroup.MessageInfo
                    .invitedAdmin(senderName, promotionMessage.groupName)
                    .previewText
                    .deformatted()
                
                switch bodyText {
                    case .some(let result): return result
                    case .none:
                        Log.warn(cat, "Failed to process body for group invite message, using generic body.")
                        return "messageNewYouveGot"
                            .putNumber(1)
                            .localized()
                }
                
            /// Fallback to something generic
            default:
                Log.error(cat, "Failed to process body for unexpected message type (variant: \(Message.Variant(from: message).map { "\($0)" } ?? "UNKNWON")), using generic body.")
                return "messageNewYouveGot"
                    .putNumber(1)
                    .localized()
        }
    }
    
    func notifyUser(
        cat: Log.Category,
        message: Message,
        threadId: String,
        threadVariant: SessionThread.Variant,
        interactionIdentifier: String,
        interactionVariant: Interaction.Variant?,
        attachmentDescriptionInfo: [Attachment.DescriptionInfo]?,
        openGroupUrlInfo: LibSession.OpenGroupUrlInfo?,
        applicationState: UIApplication.State,
        extensionBaseUnreadCount: Int?,
        currentUserSessionIds: Set<String>,
        displayNameRetriever: DisplayNameRetriever,
        groupNameRetriever: (String, SessionThread.Variant) -> String?,
        shouldShowForMessageRequest: () -> Bool
    ) throws {
        let isMessageRequest: Bool = dependencies.mutate(cache: .libSession) { cache in
            cache.isMessageRequest(
                threadId: threadId,
                threadVariant: threadVariant
            )
        }
        let settings: Preferences.NotificationSettings = settings(
            threadId: threadId,
            threadVariant: threadVariant
        )

        /// Ensure we should be showing a notification for the thread
        try ensureWeShouldShowNotification(
            message: message,
            threadId: threadId,
            threadVariant: threadVariant,
            interactionVariant: interactionVariant,
            isMessageRequest: isMessageRequest,
            notificationSettings: settings,
            openGroupUrlInfo: openGroupUrlInfo,
            currentUserSessionIds: currentUserSessionIds,
            shouldShowForMessageRequest: shouldShowForMessageRequest,
            using: dependencies
        )
        
        /// Actually add the notification
        addNotificationRequest(
            content: NotificationContent(
                threadId: threadId,
                threadVariant: threadVariant,
                identifier: {
                    switch (message as? VisibleMessage)?.reaction {
                        case .some: return dependencies.randomUUID().uuidString
                        default:
                            return Interaction.notificationIdentifier(
                                for: interactionIdentifier,
                                threadId: threadId,
                                shouldGroupMessagesForThread: (threadVariant == .community)
                            )
                    }
                }(),
                category: .incomingMessage,
                groupingIdentifier: (isMessageRequest ?
                    .messageRequest :
                    .threadId(threadId)
                ),
                title: try notificationTitle(
                    cat: cat,
                    message: message,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    isMessageRequest: isMessageRequest,
                    notificationSettings: settings,
                    displayNameRetriever: displayNameRetriever,
                    groupNameRetriever: groupNameRetriever,
                    using: dependencies
                ),
                body: notificationBody(
                    cat: cat,
                    message: message,
                    threadVariant: threadVariant,
                    isMessageRequest: isMessageRequest,
                    notificationSettings: settings,
                    interactionVariant: interactionVariant,
                    attachmentDescriptionInfo: attachmentDescriptionInfo,
                    currentUserSessionIds: currentUserSessionIds,
                    displayNameRetriever: displayNameRetriever,
                    using: dependencies
                ),
                sound: settings.sound,
                userInfo: notificationUserInfo(threadId: threadId, threadVariant: threadVariant),
                applicationState: applicationState
            ),
            notificationSettings: settings,
            extensionBaseUnreadCount: extensionBaseUnreadCount
        )
    }
}

// MARK: - NoopNotificationsManager

public struct NoopNotificationsManager: NotificationsManagerType, NoopDependency {
    public let dependencies: Dependencies
    
    public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    public func setDelegate(_ delegate: (any UNUserNotificationCenterDelegate)?) {}
    
    public func registerSystemNotificationSettings() -> AnyPublisher<Void, Never> {
        return Just(()).eraseToAnyPublisher()
    }
    
    public func settings(threadId: String?, threadVariant: SessionThread.Variant) -> Preferences.NotificationSettings {
        return Preferences.NotificationSettings(
            previewType: .defaultPreviewType,
            sound: .defaultNotificationSound,
            mentionsOnly: false,
            mutedUntil: nil
        )
    }
    
    public func updateSettings(threadId: String, threadVariant: SessionThread.Variant, mentionsOnly: Bool, mutedUntil: TimeInterval?) {
    }
    
    public func notificationUserInfo(threadId: String, threadVariant: SessionThread.Variant) -> [String: Any] {
        return [:]
    }
    
    public func notificationShouldPlaySound(applicationState: UIApplication.State) -> Bool {
        return false
    }
    
    public func notifyForFailedSend(
        threadId: String,
        threadVariant: SessionThread.Variant,
        applicationState: UIApplication.State
    ) {}
    public func scheduleSessionNetworkPageLocalNotifcation(force: Bool) {}
    
    public func addNotificationRequest(
        content: NotificationContent,
        notificationSettings: Preferences.NotificationSettings,
        extensionBaseUnreadCount: Int?
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
