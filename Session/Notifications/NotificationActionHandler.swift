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
    
    @MainActor func handleNotificationResponse(
        _ response: UNNotificationResponse,
        completionHandler: @escaping () -> Void
    ) {
        handleNotificationResponse(response)
            .subscribe(on: DispatchQueue.global(qos: .userInitiated), using: dependencies)
            .receive(on: DispatchQueue.main, using: dependencies)
            .sinkUntilComplete(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            completionHandler()
                            Log.error("[NotificationActionHandler] An error occured handling a notification response: \(error)")
                    }
                },
                receiveValue: { _ in completionHandler() }
            )
    }

    @MainActor func handleNotificationResponse(_ response: UNNotificationResponse) -> AnyPublisher<Void, Error> {
        assert(dependencies[singleton: .appReadiness].isAppReady)

        let userInfo: [AnyHashable: Any] = response.notification.request.content.userInfo
        let applicationState: UIApplication.State = UIApplication.shared.applicationState
        let categoryIdentifier = response.notification.request.content.categoryIdentifier

        switch response.actionIdentifier {
            case UNNotificationDefaultActionIdentifier:
                Log.debug("[NotificationActionHandler] Default action")
                switch categoryIdentifier {
                    case NotificationCategory.info.identifier:
                        return showPromotedScreen()
                            .setFailureType(to: Error.self)
                            .eraseToAnyPublisher()
                    default:
                        return showThread(userInfo: userInfo)
                            .setFailureType(to: Error.self)
                            .eraseToAnyPublisher()
                }
                
            case UNNotificationDismissActionIdentifier:
                // TODO - mark as read?
                Log.debug("[NotificationActionHandler] Dismissed notification")
                return Just(())
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
                
            default:
                // proceed
                break
        }

        guard let action = UserNotificationConfig.action(identifier: response.actionIdentifier) else {
            return Fail(error: NotificationError.failDebug("unable to find action for actionIdentifier: \(response.actionIdentifier)"))
                .eraseToAnyPublisher()
        }

        switch action {
            case .markAsRead: return markAsRead(userInfo: userInfo)
            case .reply:
                guard let textInputResponse = response as? UNTextInputNotificationResponse else {
                    return Fail(error: NotificationError.failDebug("response had unexpected type: \(response)"))
                        .eraseToAnyPublisher()
                }

                return reply(
                    userInfo: userInfo,
                    replyText: textInputResponse.userText,
                    applicationState: applicationState
                )
            
            // TODO: Remove in future release
            case .deprecatedMarkAsRead: return markAsRead(userInfo: userInfo)
            case .deprecatedReply:
                guard let textInputResponse = response as? UNTextInputNotificationResponse else {
                    return Fail(error: NotificationError.failDebug("response had unexpected type: \(response)"))
                        .eraseToAnyPublisher()
                }

                return reply(
                    userInfo: userInfo,
                    replyText: textInputResponse.userText,
                    applicationState: applicationState
                )
        }
    }

    // MARK: - Actions

    func markAsRead(userInfo: [AnyHashable: Any]) -> AnyPublisher<Void, Error> {
        guard let threadId: String = userInfo[NotificationUserInfoKey.threadId] as? String else {
            return Fail(error: NotificationError.failDebug("threadId was unexpectedly nil"))
                .eraseToAnyPublisher()
        }
        
        guard dependencies[singleton: .storage].read({ db in try SessionThread.exists(db, id: threadId) }) == true else {
            return Fail(error: NotificationError.failDebug("unable to find thread with id: \(threadId)"))
                .eraseToAnyPublisher()
        }

        return markAsRead(threadId: threadId)
    }

    func reply(
        userInfo: [AnyHashable: Any],
        replyText: String,
        applicationState: UIApplication.State
    ) -> AnyPublisher<Void, Error> {
        guard
            let threadId = userInfo[NotificationUserInfoKey.threadId] as? String,
            let threadVariantRaw = userInfo[NotificationUserInfoKey.threadVariantRaw] as? Int,
            let threadVariant: SessionThread.Variant = SessionThread.Variant(rawValue: threadVariantRaw)
        else {
            return Fail<Void, Error>(error: NotificationError.failDebug("thread information was unexpectedly nil"))
                .eraseToAnyPublisher()
        }
        
        return dependencies[singleton: .storage]
            .writePublisher { [dependencies] db -> (Message, Message.Destination, Int64?, AuthenticationMethod) in
                guard (try? SessionThread.exists(db, id: threadId)) == true else {
                    throw NotificationError.failDebug("unable to find thread with id: \(threadId)")
                }
                
                let sentTimestampMs: Int64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
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
            .tryFlatMap { [dependencies] message, destination, interactionId, authMethod -> AnyPublisher<(ResponseInfoType, Message), Error> in
                try MessageSender.preparedSend(
                    message: message,
                    to: destination,
                    namespace: destination.defaultNamespace,
                    interactionId: interactionId,
                    attachments: nil,
                    authMethod: authMethod,
                    onEvent: MessageSender.standardEventHandling(using: dependencies),
                    using: dependencies
                ).send(using: dependencies)
            }
            .map { _ in () }
            .handleEvents(
                receiveCompletion: { [dependencies] result in
                    switch result {
                        case .finished: break
                        case .failure:
                            dependencies[singleton: .notificationsManager].notifyForFailedSend(
                                threadId: threadId,
                                threadVariant: threadVariant,
                                applicationState: applicationState
                            )
                    }
                }
            )
            .eraseToAnyPublisher()
    }

    @MainActor func showThread(userInfo: [AnyHashable: Any]) -> AnyPublisher<Void, Never> {
        guard
            let threadId = userInfo[NotificationUserInfoKey.threadId] as? String,
            let threadVariantRaw = userInfo[NotificationUserInfoKey.threadVariantRaw] as? Int,
            let threadVariant: SessionThread.Variant = SessionThread.Variant(rawValue: threadVariantRaw)
        else { return showHomeVC() }

        // If this happens when the the app is not, visible we skip the animation so the thread
        // can be visible to the user immediately upon opening the app, rather than having to watch
        // it animate in from the homescreen.
        dependencies[singleton: .app].presentConversationCreatingIfNeeded(
            for: threadId,
            variant: threadVariant,
            action: .none,
            dismissing: dependencies[singleton: .app].homePresentedViewController,
            animated: (UIApplication.shared.applicationState == .active)
        )
        
        return Just(()).eraseToAnyPublisher()
    }
    
    func showHomeVC() -> AnyPublisher<Void, Never> {
        dependencies[singleton: .app].showHomeView()
        return Just(()).eraseToAnyPublisher()
    }
    
    func showPromotedScreen() -> AnyPublisher<Void, Never> {
        dependencies[singleton: .app].showPromotedScreen()
        return Just(()).eraseToAnyPublisher()
    }
    
    private func markAsRead(threadId: String) -> AnyPublisher<Void, Error> {
        return dependencies[singleton: .storage]
            .writePublisher { [dependencies] db in
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
            .eraseToAnyPublisher()
    }
}
