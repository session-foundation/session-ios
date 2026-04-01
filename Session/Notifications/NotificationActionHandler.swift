// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SignalUtilitiesKit
import SessionNetworkingKit
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let notificationActionHandler: SingletonConfig<NotificationActionHandler> = Dependencies.create(
        identifier: "notificationActionHandler",
        createInstance: { dependencies, _ in NotificationActionHandler(using: dependencies) }
    )
}

// MARK: - NotificationActionHandler

public class NotificationActionHandler {
    private let dependencies: Dependencies
    
    // MARK: - Initialization
    
    init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Handling
    
    func handleNotificationResponse(_ response: UNNotificationResponse) async {
        let userInfo: [AnyHashable: Any] = response.notification.request.content.userInfo
        let applicationState: UIApplication.State = await MainActor.run {
            UIApplication.shared.applicationState
        }
        let categoryIdentifier = response.notification.request.content.categoryIdentifier

        switch response.actionIdentifier {
            case UNNotificationDefaultActionIdentifier:
                Log.debug("[NotificationActionHandler] Default action")
                switch categoryIdentifier {
                    case NotificationCategory.info.identifier:
                        await MainActor.run { [weak self] in
                            self?.showPromotedScreen()
                        }
                        
                    default:
                        await showThread(
                            userInfo: userInfo,
                            applicationState: applicationState
                        )
                }
                
            case UNNotificationDismissActionIdentifier:
                // TODO: mark as read?
                Log.debug("[NotificationActionHandler] Dismissed notification")
                return
                
            default: break
        }

        do {
            guard let action = UserNotificationConfig.action(identifier: response.actionIdentifier) else {
                throw NotificationError.failDebug("unable to find action for actionIdentifier: \(response.actionIdentifier)")
            }
            
            switch action {
                case .markAsRead: try await markAsRead(userInfo: userInfo)
                case .reply:
                    guard let textInputResponse = response as? UNTextInputNotificationResponse else {
                        throw NotificationError.failDebug("response had unexpected type: \(response)")
                    }
                    
                    try await reply(
                        userInfo: userInfo,
                        replyText: textInputResponse.userText,
                        applicationState: applicationState
                    )
            }
        }
        catch {
            Log.error("[NotificationActionHandler] An error occured handling a notification response: \(error)")
        }
    }

    // MARK: - Actions
    
    @MainActor func showHomeVC() {
        dependencies[singleton: .app].showHomeView()
    }
    
    @MainActor func showPromotedScreen() {
        dependencies[singleton: .app].showPromotedScreen()
    }

    private func markAsRead(userInfo: [AnyHashable: Any]) async throws {
        guard let threadId: String = userInfo[NotificationUserInfoKey.threadId] as? String else {
            throw NotificationError.failDebug("threadId was unexpectedly nil")
        }
        
        let threadExists: Bool = try await dependencies[singleton: .storage].read { db in
            try SessionThread.exists(db, id: threadId)
        }
        
        guard threadExists else {
            throw NotificationError.failDebug("unable to find thread with id: \(threadId)")
        }

        try await markAsRead(threadId: threadId)
    }

    private func reply(
        userInfo: [AnyHashable: Any],
        replyText: String,
        applicationState: UIApplication.State
    ) async throws {
        guard
            let threadId = userInfo[NotificationUserInfoKey.threadId] as? String,
            let threadVariantRaw = userInfo[NotificationUserInfoKey.threadVariantRaw] as? Int,
            let threadVariant: SessionThread.Variant = SessionThread.Variant(rawValue: threadVariantRaw)
        else {
            throw NotificationError.failDebug("thread information was unexpectedly nil")
        }
        
        typealias Info = (
            message: Message,
            destination: Message.Destination,
            interactionId: Int64?,
            authMethod: AuthenticationMethod
        )
        
        do {
            let info: Info = try await dependencies[singleton: .storage].write { [dependencies] db -> Info in
                guard (try? SessionThread.exists(db, id: threadId)) == true else {
                    throw NotificationError.failDebug("unable to find thread with id: \(threadId)")
                }
                
                let sentTimestampMs: Int64 = dependencies.networkOffsetTimestampMs()
                let destinationDisappearingMessagesConfiguration: DisappearingMessagesConfiguration? = try? DisappearingMessagesConfiguration
                    .filter(id: threadId)
                    .filter(DisappearingMessagesConfiguration.Columns.isEnabled == true)
                    .fetchOne(db)
                let interaction: Interaction = try Interaction(
                    threadId: threadId,
                    threadVariant: threadVariant,
                    authorId: dependencies[cache: .general].sessionId.hexString,
                    variant: .standardOutgoing,
                    body: replyText,
                    timestampMs: sentTimestampMs,
                    hasMention: Interaction.isUserMentioned(db, threadId: threadId, body: replyText, using: dependencies),
                    expiresInSeconds: destinationDisappearingMessagesConfiguration?.expiresInSeconds(),
                    expiresStartedAtMs: destinationDisappearingMessagesConfiguration?.initialExpiresStartedAtMs(
                        sentTimestampMs: Double(sentTimestampMs)
                    ),
                    using: dependencies
                ).inserted(db)
                
                try Interaction.markAsRead(
                    db,
                    interactionId: interaction.id,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    includingOlder: true,
                    trySendReadReceipt: SessionThread.canSendReadReceipt(
                        threadId: threadId,
                        threadVariant: threadVariant,
                        using: dependencies
                    ),
                    using: dependencies
                )
                
                let visibleMessage: VisibleMessage = VisibleMessage.from(db, interaction: interaction)
                let destination: Message.Destination = try Message.Destination.from(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant
                )
                let authMethod: AuthenticationMethod = try Authentication.with(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    using: dependencies
                )
                
                return (visibleMessage, destination, interaction.id, authMethod)
            }
            try await MessageSender.send(
                message: info.message,
                to: info.destination,
                namespace: info.destination.defaultNamespace,
                interactionId: info.interactionId,
                attachments: nil,
                authMethod: info.authMethod,
                onEvent: MessageSender.standardEventHandling(using: dependencies),
                using: dependencies
            )
        }
        catch {
            dependencies[singleton: .notificationsManager].notifyForFailedSend(
                threadId: threadId,
                threadVariant: threadVariant,
                applicationState: applicationState
            )
        }
    }

    private func showThread(
        userInfo: [AnyHashable: Any],
        applicationState: UIApplication.State
    ) async {
        guard
            let threadId = userInfo[NotificationUserInfoKey.threadId] as? String,
            let threadVariantRaw = userInfo[NotificationUserInfoKey.threadVariantRaw] as? Int,
            let threadVariant: SessionThread.Variant = SessionThread.Variant(rawValue: threadVariantRaw)
        else { return await MainActor.run { [weak self] in self?.showHomeVC() } }

        /// If this happens when the the app is not, visible we skip the animation so the thread can be visible to the user immediately
        /// upon opening the app, rather than having to watch it animate in from the homescreen.
        await dependencies[singleton: .app].presentConversationCreatingIfNeeded(
            for: threadId,
            variant: threadVariant,
            action: .none,
            dismissing: dependencies[singleton: .app].homePresentedViewController,
            animated: (applicationState == .active)
        )
    }
    
    private func markAsRead(threadId: String) async throws {
        try await dependencies[singleton: .storage].write { [dependencies] db in
            guard
                let threadVariant: SessionThread.Variant = try SessionThread
                    .filter(id: threadId)
                    .select(.variant)
                    .asRequest(of: SessionThread.Variant.self)
                    .fetchOne(db),
                let lastInteractionId: Int64 = try Interaction
                    .select(.id)
                    .filter(Interaction.Columns.threadId == threadId)
                    .order(Interaction.Columns.timestampMs.desc)
                    .asRequest(of: Int64.self)
                    .fetchOne(db)
            else { throw NotificationError.failDebug("unable to required thread info: \(threadId)") }

            try Interaction.markAsRead(
                db,
                interactionId: lastInteractionId,
                threadId: threadId,
                threadVariant: threadVariant,
                includingOlder: true,
                trySendReadReceipt: SessionThread.canSendReadReceipt(
                    threadId: threadId,
                    threadVariant: threadVariant,
                    using: dependencies
                ),
                using: dependencies
            )
        }
    }
}
