// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import AVFAudio
import Combine
import GRDB
import CallKit
import UserNotifications
import BackgroundTasks
import SessionMessagingKit
import SessionSnodeKit
import SignalUtilitiesKit
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("NotificationServiceExtension", defaultLevel: .info)
}

// MARK: - NotificationServiceExtension

public final class NotificationServiceExtension: UNNotificationServiceExtension {
    // Called via the OS so create a default 'Dependencies' instance
    private var dependencies: Dependencies = Dependencies.createEmpty()
    private var startTime: CFTimeInterval = 0
    private var contentHandler: ((UNNotificationContent) -> Void)?
    private var request: UNNotificationRequest?
    @ThreadSafe private var hasCompleted: Bool = false

    // stringlint:ignore_start
    public static let isFromRemoteKey = "remote"
    public static let threadIdKey = "Signal.AppNotificationsUserInfoKey.threadId"
    public static let threadVariantRaw = "Signal.AppNotificationsUserInfoKey.threadVariantRaw"
    public static let threadNotificationCounter = "Session.AppNotificationsUserInfoKey.threadNotificationCounter"
    private static let callPreOfferLargeNotificationSupressionDuration: TimeInterval = 30
    // stringlint:ignore_stop

    // MARK: Did receive a remote push notification request
    
    override public func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.startTime = CACurrentMediaTime()
        self.contentHandler = contentHandler
        self.request = request
        
        /// Create a new `Dependencies` instance each time so we don't need to worry about state from previous
        /// notifications causing issues with new notifications
        self.dependencies = Dependencies.createEmpty()
        
        // It's technically possible for 'completeSilently' to be called twice due to the NSE timeout so
        self.hasCompleted = false
        
        // Abort if the main app is running
        guard !dependencies[defaults: .appGroup, key: .isMainAppActive] else {
            return self.completeSilenty(.ignoreDueToMainAppRunning, requestId: request.identifier)
        }
        
        guard let notificationContent = request.content.mutableCopy() as? UNMutableNotificationContent else {
            return self.completeSilenty(.ignoreDueToNoContentFromApple, requestId: request.identifier)
        }
        
        Log.info(.cat, "didReceive called with requestId: \(request.identifier).")
        
        /// Create the context if we don't have it (needed before _any_ interaction with the database)
        if !dependencies[singleton: .appContext].isValid {
            dependencies.set(singleton: .appContext, to: NotificationServiceExtensionContext(using: dependencies))
            Dependencies.setIsRTLRetriever(requiresMainThread: false) {
                NotificationServiceExtensionContext.determineDeviceRTL()
            }
        }
        
        /// Actually perform the setup
        self.performSetup(requestId: request.identifier) { [weak self] in
            self?.handleNotification(notificationContent, requestId: request.identifier)
        }
    }
    
    private func handleNotification(_ notificationContent: UNMutableNotificationContent, requestId: String) {
        let (maybeData, metadata, result) = PushNotificationAPI.processNotification(
            notificationContent: notificationContent,
            using: dependencies
        )
        
        guard
            (result == .success || result == .legacySuccess),
            let data: Data = maybeData
        else {
            switch (result, metadata.namespace.isConfigNamespace) {
                // If we got an explicit failure, or we got a success but no content then show
                // the fallback notification
                case (.success, false), (.legacySuccess, false), (.failure, false):
                    return self.handleFailure(
                        for: notificationContent,
                        metadata: metadata,
                        threadVariant: nil,
                        threadDisplayName: nil,
                        resolution: .errorProcessing(result),
                        requestId: requestId
                    )
                
                case (.success, _), (.legacySuccess, _), (.failure, _):
                    return self.completeSilenty(.errorProcessing(result), requestId: requestId)
                
                // Just log if the notification was too long (a ~2k message should be able to fit so
                // these will most commonly be call or config messages)
                case (.successTooLong, _):
                    return self.completeSilenty(.ignoreDueToContentSize(metadata), requestId: requestId)
                
                case (.failureNoContent, _): return self.completeSilenty(.errorNoContent(metadata), requestId: requestId)
                case (.legacyFailure, _): return self.completeSilenty(.errorNoContentLegacy, requestId: requestId)
                case (.legacyForceSilent, _):
                    return self.completeSilenty(.ignoreDueToNonLegacyGroupLegacyNotification, requestId: requestId)
            }
        }
        
        let isCallOngoing: Bool = (
            dependencies[defaults: .appGroup, key: .isCallOngoing] &&
            (dependencies[defaults: .appGroup, key: .lastCallPreOffer] != nil)
        )
        
        let hasMicrophonePermission: Bool = {
            switch Permissions.microphone {
                case .undetermined: return dependencies[defaults: .appGroup, key: .lastSeenHasMicrophonePermission]
                default: return (Permissions.microphone == .granted)
            }
        }()
        
        // HACK: It is important to use write synchronously here to avoid a race condition
        // where the completeSilenty() is called before the local notification request
        // is added to notification center
        dependencies[singleton: .storage].write { [weak self, dependencies] db in
            var processedThreadId: String?
            var processedThreadVariant: SessionThread.Variant?
            var threadDisplayName: String?
            
            do {
                let processedMessage: ProcessedMessage = try Message.processRawReceivedMessageAsNotification(
                    db,
                    data: data,
                    metadata: metadata,
                    using: dependencies
                )
                
                switch processedMessage {
                    /// Custom handle config messages (as they don't get handled by the normal `MessageReceiver.handle` call
                    case .config(let swarmPublicKey, let namespace, let serverHash, let serverTimestampMs, let data):
                        try dependencies.mutate(cache: .libSession) { cache in
                            try cache.handleConfigMessages(
                                db,
                                swarmPublicKey: swarmPublicKey,
                                messages: [
                                    ConfigMessageReceiveJob.Details.MessageInfo(
                                        namespace: namespace,
                                        serverHash: serverHash,
                                        serverTimestampMs: serverTimestampMs,
                                        data: data
                                    )
                                ]
                            )
                        }
                    
                    /// Due to the way the `CallMessage` works we need to custom handle it's behaviour within the notification
                    /// extension, for all other message types we want to just use the standard `MessageReceiver.handle` call
                    case .standard(let threadId, let threadVariant, _, let messageInfo) where messageInfo.message is CallMessage:
                        processedThreadId = threadId
                        processedThreadVariant = threadVariant
                        
                        guard let callMessage = messageInfo.message as? CallMessage else {
                            throw MessageReceiverError.ignorableMessage
                        }
                        
                        // Throw if the message is outdated and shouldn't be processed
                        try MessageReceiver.throwIfMessageOutdated(
                            db,
                            message: messageInfo.message,
                            threadId: threadId,
                            threadVariant: threadVariant,
                            using: dependencies
                        )
                        
                        // FIXME: Do we need to call it here? It does nothing other than log what kind of message we received
                        try MessageReceiver.handleCallMessage(
                            db,
                            threadId: threadId,
                            threadVariant: threadVariant,
                            message: callMessage,
                            using: dependencies
                        )
                        
                        guard case .preOffer = callMessage.kind else {
                            throw MessageReceiverError.ignorableMessage
                        }
                        
                        switch ((db[.areCallsEnabled] && hasMicrophonePermission), isCallOngoing) {
                            case (false, _):
                                if
                                    let sender: String = callMessage.sender,
                                    let interaction: Interaction = try MessageReceiver.insertCallInfoMessage(
                                        db,
                                        for: callMessage,
                                        state: (db[.areCallsEnabled] ? .permissionDeniedMicrophone : .permissionDenied),
                                        using: dependencies
                                    )
                                {
                                    let thread: SessionThread = try SessionThread.upsert(
                                        db,
                                        id: sender,
                                        variant: .contact,
                                        values: SessionThread.TargetValues(
                                            creationDateTimestamp: .useExistingOrSetTo(
                                                (dependencies[cache: .snodeAPI].currentOffsetTimestampMs() / 1000)
                                            ),
                                            shouldBeVisible: .useExisting
                                        ),
                                        using: dependencies
                                    )

                                    // Notify the user if the call message wasn't already read
                                    if !interaction.wasRead {
                                        dependencies[singleton: .notificationsManager].notifyUser(
                                            db,
                                            forIncomingCall: interaction,
                                            in: thread,
                                            applicationState: .background
                                        )
                                    }
                                }
                                
                            case (true, true):
                                try MessageReceiver.handleIncomingCallOfferInBusyState(
                                    db,
                                    message: callMessage,
                                    using: dependencies
                                )
                                
                            case (true, false):
                                try MessageReceiver.insertCallInfoMessage(db, for: callMessage, using: dependencies)
                                
                                // Perform any required post-handling logic
                                try MessageReceiver.postHandleMessage(
                                    db,
                                    threadId: threadId,
                                    threadVariant: threadVariant,
                                    message: messageInfo.message,
                                    using: dependencies
                                )
                                
                                return self?.handleSuccessForIncomingCall(db, for: callMessage, requestId: requestId)
                        }
                        
                        // Perform any required post-handling logic
                        try MessageReceiver.postHandleMessage(
                            db,
                            threadId: threadId,
                            threadVariant: threadVariant,
                            message: messageInfo.message,
                            using: dependencies
                        )
                        
                    case .standard(let threadId, let threadVariant, let proto, let messageInfo):
                        processedThreadId = threadId
                        processedThreadVariant = threadVariant
                        threadDisplayName = SessionThread.displayName(
                            threadId: threadId,
                            variant: threadVariant,
                            closedGroupName: (threadVariant != .group && threadVariant != .legacyGroup ? nil :
                                try? ClosedGroup
                                    .select(.name)
                                    .filter(id: threadId)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            ),
                            openGroupName: (threadVariant != .community ? nil :
                                try? OpenGroup
                                    .select(.name)
                                    .filter(id: threadId)
                                    .asRequest(of: String.self)
                                    .fetchOne(db)
                            ),
                            isNoteToSelf: (threadId == dependencies[cache: .general].sessionId.hexString),
                            profile: (threadVariant != .contact ? nil :
                                try? Profile
                                    .filter(id: threadId)
                                    .fetchOne(db)
                            )
                        )
                        
                        try MessageReceiver.handle(
                            db,
                            threadId: threadId,
                            threadVariant: threadVariant,
                            message: messageInfo.message,
                            serverExpirationTimestamp: messageInfo.serverExpirationTimestamp,
                            associatedWithProto: proto,
                            using: dependencies
                        )
                }
                
                db.afterNextTransaction(
                    onCommit: { _ in self?.completeSilenty(.success(metadata), requestId: requestId) },
                    onRollback: { _ in self?.completeSilenty(.errorTransactionFailure, requestId: requestId) }
                )
            }
            catch {
                // If an error occurred we want to rollback the transaction (by throwing) and then handle
                // the error outside of the database
                let handleError = {
                    // Dispatch to the next run loop to ensure we are out of the database write thread before
                    // handling the result (and suspending the database)
                    DispatchQueue.main.async {
                        switch (error, processedThreadVariant, metadata.namespace.isConfigNamespace) {
                            case (MessageReceiverError.noGroupKeyPair, _, _):
                                self?.completeSilenty(.errorLegacyGroupKeysMissing, requestId: requestId)

                            case (MessageReceiverError.outdatedMessage, _, _):
                                self?.completeSilenty(.ignoreDueToOutdatedMessage, requestId: requestId)
                                
                            case (MessageReceiverError.ignorableMessage, _, _):
                                self?.completeSilenty(.ignoreDueToRequiresNoNotification, requestId: requestId)
                                
                            case (MessageReceiverError.duplicateMessage, _, _),
                                (MessageReceiverError.duplicateControlMessage, _, _),
                                (MessageReceiverError.duplicateMessageNewSnode, _, _):
                                self?.completeSilenty(.ignoreDueToDuplicateMessage, requestId: requestId)
                                
                            /// If it was a `decryptionFailed` error, but it was for a config namespace then just fail silently (don't
                            /// want to show the fallback notification in this case)
                            case (MessageReceiverError.decryptionFailed, _, true):
                                self?.completeSilenty(.errorMessageHandling(.decryptionFailed), requestId: requestId)
                                
                            /// If it was a `decryptionFailed` error for a group conversation and the group doesn't exist or
                            /// doesn't have auth info (ie. group destroyed or member kicked), then just fail silently (don't want
                            /// to show the fallback notification in these cases)
                            case (MessageReceiverError.decryptionFailed, .group, _):
                                guard
                                    let threadId: String = processedThreadId,
                                    let group: ClosedGroup = try? ClosedGroup.fetchOne(db, id: threadId), (
                                        group.groupIdentityPrivateKey != nil ||
                                        group.authData != nil
                                    )
                                else {
                                    self?.completeSilenty(.errorMessageHandling(.decryptionFailed), requestId: requestId)
                                    return
                                }
                                
                                /// The thread exists and we should have been able to decrypt so show the fallback message
                                self?.handleFailure(
                                    for: notificationContent,
                                    metadata: metadata,
                                    threadVariant: processedThreadVariant,
                                    threadDisplayName: threadDisplayName,
                                    resolution: .errorMessageHandling(.decryptionFailed),
                                    requestId: requestId
                                )
                                
                            case (let msgError as MessageReceiverError, _, _):
                                self?.handleFailure(
                                    for: notificationContent,
                                    metadata: metadata,
                                    threadVariant: processedThreadVariant,
                                    threadDisplayName: threadDisplayName,
                                    resolution: .errorMessageHandling(msgError),
                                    requestId: requestId
                                )
                                
                            default:
                                self?.handleFailure(
                                    for: notificationContent,
                                    metadata: metadata,
                                    threadVariant: processedThreadVariant,
                                    threadDisplayName: threadDisplayName,
                                    resolution: .errorOther(error),
                                    requestId: requestId
                                )
                        }
                    }
                }
                
                db.afterNextTransaction(
                    onCommit: { _ in  handleError() },
                    onRollback: { _ in handleError() }
                )
                throw error
            }
        }
    }

    // MARK: Setup

    private func performSetup(requestId: String, completion: @escaping () -> Void) {
        Log.info(.cat, "Performing setup for requestId: \(requestId).")

        dependencies.warmCache(cache: .appVersion)

        AppSetup.setupEnvironment(
            requestId: requestId,
            appSpecificBlock: { [dependencies] in
                // stringlint:ignore_start
                Log.setup(with: Logger(
                    primaryPrefix: "NotificationServiceExtension",
                    customDirectory: "\(dependencies[singleton: .fileManager].appSharedDataDirectoryPath)/Logs/NotificationExtension",
                    using: dependencies
                ))
                // stringlint:ignore_stop
                
                /// The `NotificationServiceExtension` needs custom behaviours for it's notification presenter so set it up here
                dependencies.set(singleton: .notificationsManager, to: NSENotificationPresenter(using: dependencies))
                
                // Setup LibSession
                LibSession.setupLogger(using: dependencies)
                
                // Configure the different targets
                SNUtilitiesKit.configure(
                    networkMaxFileSize: Network.maxFileSize,
                    localizedFormatted: { helper, font in NSAttributedString() },
                    localizedDeformatted: { helper in NSENotificationPresenter.localizedDeformatted(helper) },
                    using: dependencies
                )
                SNMessagingKit.configure(using: dependencies)
            },
            migrationsCompletion: { [weak self, dependencies] result in
                switch result {
                    case .failure(let error): self?.completeSilenty(.errorDatabaseMigrations(error), requestId: requestId)
                    case .success:
                        DispatchQueue.main.async {
                            // Ensure storage is actually valid
                            guard dependencies[singleton: .storage].isValid else {
                                self?.completeSilenty(.errorDatabaseInvalid, requestId: requestId)
                                return
                            }
                            
                            // We should never receive a non-voip notification on an app that doesn't support
                            // app extensions since we have to inform the service we wanted these, so in theory
                            // this path should never occur. However, the service does have our push token
                            // so it is possible that could change in the future. If it does, do nothing
                            // and don't disturb the user. Messages will be processed when they open the app.
                            guard dependencies[singleton: .storage, key: .isReadyForAppExtensions] else {
                                self?.completeSilenty(.errorNotReadyForExtensions, requestId: requestId)
                                return
                            }
                            
                            // If the app wasn't ready then mark it as ready now
                            if !dependencies[singleton: .appReadiness].isAppReady {
                                // Note that this does much more than set a flag; it will also run all deferred blocks.
                                dependencies[singleton: .appReadiness].setAppReady()
                            }

                            completion()
                        }
                }
            },
            using: dependencies
        )
    }
    
    // MARK: Handle completion
    
    override public func serviceExtensionTimeWillExpire() {
        // Called just before the extension will be terminated by the system.
        // Use this as an opportunity to deliver your "best attempt" at modified content, otherwise the original push payload will be used.
        completeSilenty(.errorTimeout, requestId: (request?.identifier ?? "N/A"))   // stringlint:ignore
    }
    
    private func completeSilenty(_ resolution: NotificationResolution, requestId: String) {
        // This can be called from within database threads so to prevent blocking and weird
        // behaviours make sure to send it to the main thread instead
        guard Thread.isMainThread else {
            return DispatchQueue.main.async { [weak self] in
                self?.completeSilenty(resolution, requestId: requestId)
            }
        }
        
        // Ensure we only run this once
        guard _hasCompleted.performUpdateAndMap({ (true, $0) }) == false else { return }
        
        let silentContent: UNMutableNotificationContent = UNMutableNotificationContent()
        
        switch resolution {
            case .ignoreDueToMainAppRunning: break
            default:
                /// Update the app badge in case the unread count changed
                if
                    let unreadCount: Int = dependencies[singleton: .storage].read({ [dependencies] db in
                        try Interaction.fetchAppBadgeUnreadCount(db, using: dependencies)
                    })
                {
                    silentContent.badge = NSNumber(value: unreadCount)
                }
                
                dependencies[singleton: .storage].suspendDatabaseAccess()
        }
        
        let duration: CFTimeInterval = (CACurrentMediaTime() - startTime)
        Log.custom(resolution.logLevel, [.cat], "\(resolution) after \(.seconds(duration), unit: .ms), requestId: \(requestId).")
        Log.flush()
        Log.reset()
        
        self.contentHandler!(silentContent)
    }
    
    private func handleSuccessForIncomingCall(
        _ db: Database,
        for callMessage: CallMessage,
        requestId: String
    ) {
        if #available(iOSApplicationExtension 14.5, *), Preferences.isCallKitSupported {
            guard let caller: String = callMessage.sender, let timestamp = callMessage.sentTimestampMs else { return }
            
            let reportCall: () -> () = { [weak self, dependencies] in
                // stringlint:ignore_start
                let payload: [String: Any] = [
                    "uuid": callMessage.uuid,
                    "caller": caller,
                    "timestamp": timestamp
                ]
                // stringlint:ignore_stop
                
                CXProvider.reportNewIncomingVoIPPushPayload(payload) { error in
                    if let error = error {
                        Log.error(.cat, "Failed to notify main app of call message: \(error).")
                        dependencies[singleton: .storage].read { db in
                            self?.handleFailureForVoIP(db, for: callMessage, requestId: requestId)
                        }
                    }
                    else {
                        dependencies[defaults: .appGroup, key: .lastCallPreOffer] = Date()
                        self?.completeSilenty(.successCall, requestId: requestId)
                    }
                }
            }
            
            db.afterNextTransaction(
                onCommit: { _ in reportCall() },
                onRollback: { _ in reportCall() }
            )
        }
        else {
            self.handleFailureForVoIP(db, for: callMessage, requestId: requestId)
        }
    }
    
    private func handleFailureForVoIP(_ db: Database, for callMessage: CallMessage, requestId: String) {
        let notificationContent = UNMutableNotificationContent()
        notificationContent.userInfo = [ NotificationServiceExtension.isFromRemoteKey : true ]
        notificationContent.title = Constants.app_name
        
        /// Update the app badge in case the unread count changed
        if let unreadCount: Int = try? Interaction.fetchAppBadgeUnreadCount(db, using: dependencies) {
            notificationContent.badge = NSNumber(value: unreadCount)
        }
        
        if let sender: String = callMessage.sender {
            let senderDisplayName: String = Profile.displayName(db, id: sender, threadVariant: .contact, using: dependencies)
            notificationContent.body = "callsIncoming"
                .put(key: "name", value: senderDisplayName)
                .localized()
        }
        else {
            notificationContent.body = "callsIncomingUnknown".localized()
        }
        
        let identifier = self.request?.identifier ?? UUID().uuidString
        let request = UNNotificationRequest(identifier: identifier, content: notificationContent, trigger: nil)
        let semaphore = DispatchSemaphore(value: 0)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Log.error(.cat, "Failed to add notification request for requestId: \(requestId) due to error: \(error).")
            }
            semaphore.signal()
        }
        semaphore.wait()
        Log.info(.cat, "Add remote notification request for requestId: \(requestId).")
        
        db.afterNextTransaction(
            onCommit: { [weak self] _ in self?.completeSilenty(.errorCallFailure, requestId: requestId) },
            onRollback: { [weak self] _ in self?.completeSilenty(.errorTransactionFailure, requestId: requestId) }
        )
    }

    private func handleFailure(
        for content: UNMutableNotificationContent,
        metadata: PushNotificationAPI.NotificationMetadata,
        threadVariant: SessionThread.Variant?,
        threadDisplayName: String?,
        resolution: NotificationResolution,
        requestId: String
    ) {
        // This can be called from within database threads so to prevent blocking and weird
        // behaviours make sure to send it to the main thread instead
        guard Thread.isMainThread else {
            return DispatchQueue.main.async { [weak self] in
                self?.handleFailure(
                    for: content,
                    metadata: metadata,
                    threadVariant: threadVariant,
                    threadDisplayName: threadDisplayName,
                    resolution: resolution,
                    requestId: requestId
                )
            }
        }
        
        let duration: CFTimeInterval = (CACurrentMediaTime() - startTime)
        let previewType: Preferences.NotificationPreviewType = dependencies[singleton: .storage, key: .preferencesNotificationPreviewType]
            .defaulting(to: .nameAndPreview)
        Log.error(.cat, "\(resolution) after \(.seconds(duration), unit: .ms), showing generic failure message for message from namespace: \(metadata.namespace), requestId: \(requestId).")
        
        /// Now we are done with the database, we should suspend it
        if !dependencies[defaults: .appGroup, key: .isMainAppActive] {
            dependencies[singleton: .storage].suspendDatabaseAccess()
        }
        
        /// Clear the logger
        Log.flush()
        Log.reset()
        
        content.title = Constants.app_name
        content.userInfo = [ NotificationServiceExtension.isFromRemoteKey: true ]
        
        /// If it's a notification for a group conversation, the notification preferences are right and we have a name for the group
        /// then we should include it in the notification content
        switch (threadVariant, previewType, threadDisplayName) {
            case (.group, .nameAndPreview, .some(let name)), (.group, .nameNoPreview, .some(let name)),
                (.legacyGroup, .nameAndPreview, .some(let name)), (.legacyGroup, .nameNoPreview, .some(let name)):
                content.body = "messageNewYouveGotGroup"
                    .putNumber(1)
                    .put(key: "group_name", value: name)
                    .localized()
                
            default:
                content.body = "messageNewYouveGot"
                    .putNumber(1)
                    .localized()
        }
        
        contentHandler!(content)
        hasCompleted = true
    }
}
