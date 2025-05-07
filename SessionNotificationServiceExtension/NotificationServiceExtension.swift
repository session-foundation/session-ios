// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import AVFAudio
import Combine
import GRDB
import CallKit
import UserNotifications
import BackgroundTasks
import SessionUIKit
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
    private var cachedNotificationInfo: NotificationInfo = .invalid
    @ThreadSafe private var hasCompleted: Bool = false
    
    // MARK: Did receive a remote push notification request
    
    override public func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        self.startTime = CACurrentMediaTime()
        self.cachedNotificationInfo = self.cachedNotificationInfo.with(requestId: request.identifier)
        self.cachedNotificationInfo = self.cachedNotificationInfo.with(contentHandler: contentHandler)
        
        /// Create a new `Dependencies` instance each time so we don't need to worry about state from previous
        /// notifications causing issues with new notifications
        self.dependencies = Dependencies.createEmpty()
        
        // It's technically possible for 'completeSilently' to be called twice due to the NSE timeout so
        self.hasCompleted = false
        
        // Abort if the main app is running
        guard !dependencies[defaults: .appGroup, key: .isMainAppActive] else {
            return self.completeSilenty(self.cachedNotificationInfo, .ignoreDueToMainAppRunning)
        }
        
        guard let content = request.content.mutableCopy() as? UNMutableNotificationContent else {
            return self.completeSilenty(self.cachedNotificationInfo, .ignoreDueToNoContentFromApple)
        }
        
        Log.info(.cat, "didReceive called with requestId: \(request.identifier).")
        
        /// Create the context if we don't have it (needed before _any_ interaction with the database)
        if !dependencies[singleton: .appContext].isValid {
            dependencies.set(singleton: .appContext, to: NotificationServiceExtensionContext(using: dependencies))
            Dependencies.setIsRTLRetriever(requiresMainThread: false) {
                NotificationServiceExtensionContext.determineDeviceRTL()
            }
        }
        
        /// Setup the extension and handle the notification
        var notificationInfo: NotificationInfo = self.cachedNotificationInfo.with(content: content)
        var processedNotification: ProcessedNotification = (self.cachedNotificationInfo, .invalid, "", nil, nil)
        
        do {
            try performSetup(requestId: request.identifier)
            notificationInfo = try extractNotificationInfo(notificationInfo)
            processedNotification = try processNotification(notificationInfo)
            try handleNotification(processedNotification)
        }
        catch {
            handleError(
                error,
                info: notificationInfo,
                processedNotification: processedNotification,
                contentHandler: contentHandler
            )
        }
    }
    
    // MARK: - Setup

    private func performSetup(requestId: String) throws {
        Log.info(.cat, "Performing setup for requestId: \(requestId).")
        
        dependencies.warmCache(cache: .appVersion)
        
        var migrationResult: Result<Void, Error> = .failure(StorageError.startupFailed)
        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
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
                    using: dependencies
                )
                SNMessagingKit.configure(using: dependencies)
            },
            migrationsCompletion: { result in
                migrationResult = result
                semaphore.signal()
            },
            using: dependencies
        )
        
        semaphore.wait()
        
        /// Ensure the migration was successful or throw the error
        do { _ = try migrationResult.successOrThrow() }
        catch { throw NotificationError.migration(error) }
        
        /// Ensure storage is actually valid
        guard dependencies[singleton: .storage].isValid else {
            throw NotificationError.databaseInvalid
        }
        
        /// We should never receive a non-voip notification on an app that doesn't support app extensions since we have to inform the
        /// service we wanted these, so in theory this path should never occur. However, the service does have our push token so it is
        /// possible that could change in the future. If it does, do nothing and don't disturb the user. Messages will be processed when
        /// they open the app.
        guard dependencies[singleton: .storage, key: .isReadyForAppExtensions] else {
            throw NotificationError.notReadyForExtension
        }
        
        /// If the app wasn't ready then mark it as ready now
        if !dependencies[singleton: .appReadiness].isAppReady {
            /// Note that this does much more than set a flag; it will also run all deferred blocks
            dependencies[singleton: .appReadiness].setAppReady()
        }
    }
    
    // MARK: - Notification Handling
    
    private func extractNotificationInfo(_ info: NotificationInfo) throws -> NotificationInfo {
        let (maybeData, metadata, result) = PushNotificationAPI.processNotification(
            notificationContent: info.content,
            using: dependencies
        )
        
        switch (result, maybeData, metadata.namespace.isConfigNamespace) {
            /// If we got an explicit failure, or we got a success but no content then show the fallback notification
            case (.failure, _, false), (.success, .none, false):
                throw NotificationError.processingErrorWithFallback(result, metadata)
                
            case (.success, .some(let data), _):
                return NotificationInfo(
                    content: info.content,
                    requestId: info.requestId,
                    contentHandler: info.contentHandler,
                    metadata: metadata,
                    data: data
                )
                
            default: throw NotificationError.processingError(result, metadata)
        }
    }
    
    private func processNotification(_ info: NotificationInfo) throws -> ProcessedNotification {
        let processedMessage: ProcessedMessage = try MessageReceiver.parse(
            data: info.data,
            origin: .swarm(
                publicKey: info.metadata.accountId,
                namespace: info.metadata.namespace,
                serverHash: info.metadata.hash,
                serverTimestampMs: info.metadata.createdTimestampMs,
                serverExpirationTimestamp: (
                    (TimeInterval(dependencies[cache: .snodeAPI].currentOffsetTimestampMs() + SnodeReceivedMessage.defaultExpirationMs) / 1000)
                )
            ),
            using: dependencies
        )
        try MessageDeduplication.ensureMessageIsNotADuplicate(processedMessage, using: dependencies)
        
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        var threadVariant: SessionThread.Variant?
        var threadDisplayName: String?
        
        switch processedMessage {
            case .invalid: throw MessageReceiverError.invalidMessage
            case .config:
                threadVariant = nil
                threadDisplayName = nil
                
            case .standard(let threadId, let threadVariantVal, _, let messageInfo, _):
                threadVariant = threadVariantVal
                threadDisplayName = SessionThread.displayName(
                    threadId: threadId,
                    variant: threadVariantVal,
                    closedGroupName: {
                        switch threadVariant {
                            case .legacyGroup:
                                return dependencies.mutate(cache: .libSession) { cache in
                                    let config: LibSession.Config? = cache.config(for: .userGroups, sessionId: userSessionId)
                                    
                                    return config?.groupName(groupId: threadId)
                                }
                                
                            case .group:
                                return dependencies.mutate(cache: .libSession) { cache in
                                    guard let groupInfoConfig: LibSession.Config = cache.config(for: .groupInfo, sessionId: SessionId(.group, hex: threadId)) else {
                                        let config: LibSession.Config? = cache.config(for: .userGroups, sessionId: userSessionId)
                                        
                                        return config?.groupName(groupId: threadId)
                                    }
                                    
                                    return groupInfoConfig.groupName
                                }
                                
                            default: return nil
                        }
                    }(),
                    openGroupName: nil, // Community PNs not currently supported
                    isNoteToSelf: (threadId == userSessionId.hexString),
                    profile: {
                        switch (threadVariant, threadId) {
                            case (.contact, threadId) where threadId == userSessionId.hexString:
                                return nil  // Covered by the `isNoteToSelf` above
                                
                            case (.contact, _):
                                return dependencies.mutate(cache: .libSession) { cache in
                                    let config: LibSession.Config? = cache.config(for: .contacts, sessionId: SessionId(.standard, hex: threadId))
                                    
                                    return config?.profile(contactId: threadId)
                                }
                                
                            default: return nil
                        }
                    }()
                )
        }
        
        return (
            info,
            processedMessage,
            processedMessage.threadId,
            threadVariant,
            threadDisplayName
        )
    }
    
    private func handleNotification(_ notification: ProcessedNotification) throws {
        switch notification.processedMessage {
            case .invalid: throw MessageReceiverError.invalidMessage
            case .config(let swarmPublicKey, let namespace, let serverHash, let serverTimestampMs, let data, _):
                try handleConfigMessage(
                    notification,
                    swarmPublicKey: swarmPublicKey,
                    namespace: namespace,
                    serverHash: serverHash,
                    serverTimestampMs: serverTimestampMs,
                    data: data
                )
                
            case .standard(let threadId, let threadVariant, let proto, let messageInfo, _):
                try handleStandardMessage(
                    notification,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    proto: proto,
                    messageInfo: messageInfo
                )
        }
    }
    
    private func handleConfigMessage(
        _ notification: ProcessedNotification,
        swarmPublicKey: String,
        namespace: SnodeAPI.Namespace,
        serverHash: String,
        serverTimestampMs: Int64,
        data: Data
    ) throws {
        // TODO: [Database Relocation] Handle the config message case in a separate PR
        return try dependencies.mutate(cache: .libSession) { cache in
            try cache.mergeConfigMessages(
                swarmPublicKey: swarmPublicKey,
                messages: [
                    ConfigMessageReceiveJob.Details.MessageInfo(
                        namespace: namespace,
                        serverHash: serverHash,
                        serverTimestampMs: serverTimestampMs,
                        data: data
                    )
                ],
                afterMerge: { sessionId, variant, config, _ in
                    // TODO: [Database Relocation] Handle the config message case in a separate PR
                }
            )
        }
    }
    
    private func handleStandardMessage(
        _ notification: ProcessedNotification,
        threadId: String,
        threadVariant: SessionThread.Variant,
        proto: SNProtoContent,
        messageInfo: MessageReceiveJob.Details.MessageInfo
    ) throws {
        /// Throw if the message is outdated and shouldn't be processed (this is based on pretty flaky logic which checks if the config
        /// has been updated since the message was sent - this should be reworked to be less edge-case prone in the future)
        try MessageReceiver.throwIfMessageOutdated(
            message: messageInfo.message,
            threadId: threadId,
            threadVariant: threadVariant,
            openGroupUrlInfo: nil,  /// Communities current don't support PNs
            using: dependencies
        )
        
        /// Define the `displayNameRetriever` so it can be reused
        let displayNameRetriever: (String) -> String? = { [dependencies] sessionId in
            // FIXME: Once `libSession` manages unsynced "Profile" data we should source this from there
            let contactProfile: Profile? = dependencies.mutate(cache: .libSession, config: .contacts) { config in
                config?.profile(contactId: sessionId)
            }
            let contactName: String? = contactProfile?.displayName(
                for: threadVariant,
                messageProfile: (messageInfo.message as? VisibleMessage)?.profile
            )
            
            guard contactName == nil && threadVariant == .group else { return contactName }
            
            /// If we couldn't get a direct name for the contact then try to extract their name from `GroupMembers`
            /// if it's a group conversation
            let groupSessionId: SessionId = SessionId(.group, hex: threadId)
            
            return (dependencies
                .mutate(cache: .libSession, config: .groupMembers, groupSessionId: groupSessionId) { config in
                    config?.memberProfile(memberId: sessionId)
                }?
                .displayName(for: threadVariant))
                .defaulting(to: Profile.truncated(id: sessionId, threadVariant: threadVariant))
        }
        
        /// Handle any specific logic needed for the notification extension based on the message type
        switch messageInfo.message {
            /// These have no notification-related behaviours so no need to do anything
            case is TypingIndicator, is DataExtractionNotification, is ExpirationTimerUpdate,
                is MessageRequestResponse:
                break
            
            /// `ReadReceipt` and `UnsendRequest` messages only include basic information which can be used to lookup a
            /// message so need database access in order to do anything (including removing existing notifications) so just ignore them
            case is ReadReceipt, is UnsendRequest: break
            
            /// Control messages for `group` conversations
            case is GroupUpdateInviteMessage, is GroupUpdateInfoChangeMessage,
                is GroupUpdateMemberChangeMessage, is GroupUpdatePromoteMessage,
                is GroupUpdateMemberLeftMessage, is GroupUpdateMemberLeftNotificationMessage,
                is GroupUpdateInviteResponseMessage, is GroupUpdateDeleteMemberContentMessage:
                // TODO: [Database Relocation] Handle group control messages in a separate PR
                return handleNotificationViaDatabase(notification)
                
            /// Custom `group` conversation messages (eg. `kickedMessage`)
            case is LibSessionMessage:
                // TODO: [Database Relocation] Handle the LibSession message in a separate PR
                return handleNotificationViaDatabase(notification)
                
            case var callMessage as CallMessage:
                switch callMessage.kind {
                    case .preOffer: Log.info(.calls, "Received pre-offer message with uuid: \(callMessage.uuid).")
                    case .offer: Log.info(.calls, "Received offer message.")
                    case .answer: Log.info(.calls, "Received answer message.")
                    case .endCall: Log.info(.calls, "Received end call message.")
                    case .provisionalAnswer, .iceCandidates: break
                }
                
                // TODO: [Database Relocation] Need to store 'db[.areCallsEnabled]' in libSession
                let areCallsEnabled: Bool = true // db[.areCallsEnabled]
                let hasMicrophonePermission: Bool = {
                    switch Permissions.microphone {
                        case .undetermined: return dependencies[defaults: .appGroup, key: .lastSeenHasMicrophonePermission]
                        default: return (Permissions.microphone == .granted)
                    }
                }()
                let isCallOngoing: Bool = (
                    dependencies[defaults: .appGroup, key: .isCallOngoing] &&
                    (dependencies[defaults: .appGroup, key: .lastCallPreOffer] != nil)
                )
                /// We need additional dedupe logic if the message is a `CallMessage` as multiple messages can
                /// related to the same call
                let insertAdditionalCallDedupeRecord: (CallMessage, Dependencies) throws -> Void = { callMessage, dependencies in
                    try MessageDeduplication.ensureCallMessageIsNotADuplicate(
                        threadId: threadId,
                        callMessage: callMessage,
                        using: dependencies
                    )
                    try dependencies[singleton: .extensionHelper].createDedupeRecord(
                        threadId: threadId,
                        uniqueIdentifier: callMessage.uuid
                    )
                }
                
                /// Handle the call as needed
                switch ((areCallsEnabled && hasMicrophonePermission), isCallOngoing) {
                    case (false, _):
                        /// Store the `state` on the `Message` to make it easier to handle the notification
                        try insertAdditionalCallDedupeRecord(callMessage, dependencies)
                        callMessage.state = (areCallsEnabled ? .permissionDeniedMicrophone : .permissionDenied)
                        // TODO: [Database Relocation] Will need to add the above logic prior to local notifications when handling calls
                        // TODO: [Database Relocation] Need to test that the above assignment comes through the below '.notifyUser(' call
                        
                    case (true, true):
                        Log.info(.calls, "Sending end call message because there is an ongoing call.")
                        // TODO: [Database Relocation] Need to properly implement this logic (without the database requirement)
                        fatalError("NEED TO IMPLEMENT")
//                        try MessageReceiver.handleIncomingCallOfferInBusyState(
//                            db,
//                            message: callMessage,
//                            using: dependencies
//                        )
                        
                    case (true, false):
                        guard
                            let sender: String = callMessage.sender,
                            let sentTimestampMs: UInt64 = callMessage.sentTimestampMs
                        else { throw MessageReceiverError.invalidMessage }
                        
                        /// Insert the dedupe record and then handle the message
                        try insertAdditionalCallDedupeRecord(callMessage, dependencies)
                        return handleSuccessForIncomingCall(
                            notification,
                            threadVariant: threadVariant,
                            callMessage: callMessage,
                            sender: sender,
                            sentTimestampMs: sentTimestampMs,
                            displayNameRetriever: displayNameRetriever
                        )
                }
                
            case is VisibleMessage: break
            default: throw MessageReceiverError.unknownMessage(proto)
        }
        
        /// Try to show a notification for the message
        ///
        /// **Note:** No need to check blinded ids as Communities currently don't support PNs
        let currentUserSessionIds: Set<String> = [dependencies[cache: .general].sessionId.hexString]
        try dependencies[singleton: .notificationsManager].notifyUser(
            message: messageInfo.message,
            threadId: threadId,
            threadVariant: threadVariant,
            interactionId: 0,
            interactionVariant: Interaction.Variant(
                message: messageInfo.message,
                currentUserSessionIds: currentUserSessionIds
            ),
            attachmentDescriptionInfo: proto.dataMessage?.attachments.map { attachment in
                Attachment.DescriptionInfo(id: "", proto: attachment)
            },
            openGroupUrlInfo: nil,  /// Communities currently don't support PNs
            applicationState: .background,
            currentUserSessionIds: currentUserSessionIds,
            displayNameRetriever: displayNameRetriever,
            shouldShowForMessageRequest: {
                !dependencies[singleton: .extensionHelper]
                    .hasAtLeastOneDedupeRecord(threadId: threadId)
            }
        )
        
        /// Write the message to disk via the `extensionHelper` so the main app will have it immediately instead of having to wait
        /// for a poll to return
        // TODO: [Database Relocation] Add in this logic
        
        /// Since we successfully handled the message we should now create the dedupe file for the message so we don't
        /// show duplicate PNs
        try MessageDeduplication.createDedupeFile(notification.processedMessage, using: dependencies)
    }
    
    private func handleError(
        _ error: Error,
        info: NotificationInfo,
        processedNotification: ProcessedNotification?,
        contentHandler: ((UNNotificationContent) -> Void)
    ) {
        switch (error, processedNotification?.threadVariant, info.metadata.namespace.isConfigNamespace) {
            case (NotificationError.migration(let error), _, _):
                self.completeSilenty(info, .errorDatabaseMigrations(error))
                
            case (NotificationError.databaseInvalid, _, _):
                self.completeSilenty(info, .errorDatabaseInvalid)
                
            case (NotificationError.notReadyForExtension, _, _):
                self.completeSilenty(info, .errorNotReadyForExtensions)
                
            case (NotificationError.processingErrorWithFallback(let result, let errorMetadata), _, _):
                self.handleFailure(
                    info.with(metadata: errorMetadata),
                    threadVariant: nil,
                    threadDisplayName: nil,
                    resolution: .errorProcessing(result)
                )
                
            /// Just log if the notification was too long (a ~2k message should be able to fit so these will most commonly be call
            /// or config messages)
            case (NotificationError.processingError(let result, let errorMetadata), _, _) where result == .successTooLong:
                self.completeSilenty(info.with(metadata: errorMetadata), .ignoreDueToContentSize(errorMetadata))
                
            case (NotificationError.processingError(let result, let errorMetadata), _, _) where result == .failureNoContent:
                self.completeSilenty(info.with(metadata: errorMetadata), .errorNoContent(errorMetadata))
                
            case (NotificationError.processingError(let result, let errorMetadata), _, _) where result == .legacyFailure:
                self.completeSilenty(info.with(metadata: errorMetadata), .errorLegacyPushNotification)
                
            case (NotificationError.processingError(let result, let errorMetadata), _, _):
                self.completeSilenty(info.with(metadata: errorMetadata), .errorProcessing(result))
                
            case (MessageReceiverError.noGroupKeyPair, _, _):
                self.completeSilenty(info, .errorLegacyPushNotification)
                
            case (MessageReceiverError.outdatedMessage, _, _):
                self.completeSilenty(info, .ignoreDueToOutdatedMessage)
                
            case (MessageReceiverError.ignorableMessage, _, _):
                self.completeSilenty(info, .ignoreDueToRequiresNoNotification)
                
            case (MessageReceiverError.duplicateMessage, _, _):
                self.completeSilenty(info, .ignoreDueToDuplicateMessage)
                
            /// If it was a `decryptionFailed` error, but it was for a config namespace then just fail silently (don't
            /// want to show the fallback notification in this case)
            case (MessageReceiverError.decryptionFailed, _, true):
                self.completeSilenty(info, .errorMessageHandling(.decryptionFailed))
                
            /// If it was a `decryptionFailed` error for a group conversation and the group doesn't exist or
            /// doesn't have auth info (ie. group destroyed or member kicked), then just fail silently (don't want
            /// to show the fallback notification in these cases)
            case (MessageReceiverError.decryptionFailed, .group, _):
                guard
                    let threadId: String = processedNotification?.threadId,
                    dependencies.mutate(cache: .libSession, config: .userGroups, { config in
                        (config?.hasCredentials(groupSessionId: SessionId(.group, hex: threadId)))
                            .defaulting(to: false)
                    })
                else {
                    self.completeSilenty(info, .errorMessageHandling(.decryptionFailed))
                    return
                }
                
                /// The thread exists and we should have been able to decrypt so show the fallback message
                self.handleFailure(
                    info,
                    threadVariant: processedNotification?.threadVariant,
                    threadDisplayName: processedNotification?.threadDisplayName,
                    resolution: .errorMessageHandling(.decryptionFailed)
                )
                
            case (let msgError as MessageReceiverError, _, _):
                self.handleFailure(
                    info,
                    threadVariant: processedNotification?.threadVariant,
                    threadDisplayName: processedNotification?.threadDisplayName,
                    resolution: .errorMessageHandling(msgError)
                )
                
            default:
                self.handleFailure(
                    info,
                    threadVariant: processedNotification?.threadVariant,
                    threadDisplayName: processedNotification?.threadDisplayName,
                    resolution: .errorOther(error)
                )
        }
    }
    
    @available(*, deprecated, message: "This function will be removed as part of the Database Relocation work, but is being build in parts so will remain for now")
    private func handleNotificationViaDatabase(_ notification: ProcessedNotification) {
        // HACK: It is important to use write synchronously here to avoid a race condition
        // where the completeSilenty() is called before the local notification request
        // is added to notification center
        dependencies[singleton: .storage].write { [weak self, dependencies] db in
            var processedThreadId: String?
            var processedThreadVariant: SessionThread.Variant?
            var threadDisplayName: String?
            
            do {
                switch notification.processedMessage {
                    case .config, .invalid: return
                    case .standard(let threadId, let threadVariant, let proto, let messageInfo, _):
                        /// Only allow the cases with don't have updated handling through
                        switch messageInfo.message {
                            case is GroupUpdateInviteMessage, is GroupUpdateInfoChangeMessage,
                                is GroupUpdateMemberChangeMessage, is GroupUpdatePromoteMessage,
                                is GroupUpdateMemberLeftMessage, is GroupUpdateMemberLeftNotificationMessage,
                                is GroupUpdateInviteResponseMessage, is GroupUpdateDeleteMemberContentMessage:
                                break
                                
                            case is LibSessionMessage: break
                            default: throw MessageReceiverError.invalidMessage
                        }
                        
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
                
                /// Since we successfully handled the message we should now create the dedupe file for the message so we don't
                /// show duplicate PNs
                try MessageDeduplication.createDedupeFile(notification.processedMessage, using: dependencies)
                
                db.afterNextTransaction(
                    onCommit: { _ in self?.completeSilenty(notification.info, .success(notification.info.metadata)) },
                    onRollback: { _ in self?.completeSilenty(notification.info, .errorTransactionFailure) }
                )
            }
            catch {
                // If an error occurred we want to rollback the transaction (by throwing) and then handle
                // the error outside of the database
                let handleError = {
                    // Dispatch to the next run loop to ensure we are out of the database write thread before
                    // handling the result (and suspending the database)
                    DispatchQueue.main.async {
                        switch (error, notification.threadVariant, notification.info.metadata.namespace.isConfigNamespace) {
                            case (MessageReceiverError.noGroupKeyPair, _, _):
                                self?.completeSilenty(notification.info, .errorLegacyPushNotification)

                            case (MessageReceiverError.outdatedMessage, _, _):
                                self?.completeSilenty(notification.info, .ignoreDueToOutdatedMessage)
                                
                            case (MessageReceiverError.ignorableMessage, _, _):
                                self?.completeSilenty(notification.info, .ignoreDueToRequiresNoNotification)
                                
                            case (MessageReceiverError.duplicateMessage, _, _):
                                self?.completeSilenty(notification.info, .ignoreDueToDuplicateMessage)
                                
                            /// If it was a `decryptionFailed` error, but it was for a config namespace then just fail silently (don't
                            /// want to show the fallback notification in this case)
                            case (MessageReceiverError.decryptionFailed, _, true):
                                self?.completeSilenty(notification.info, .errorMessageHandling(.decryptionFailed))
                                
                            /// If it was a `decryptionFailed` error for a group conversation and the group doesn't exist or
                            /// doesn't have auth info (ie. group destroyed or member kicked), then just fail silently (don't want
                            /// to show the fallback notification in these cases)
                            case (MessageReceiverError.decryptionFailed, .group, _):
                                guard
                                    let group: ClosedGroup = try? ClosedGroup.fetchOne(db, id: notification.threadId), (
                                        group.groupIdentityPrivateKey != nil ||
                                        group.authData != nil
                                    )
                                else {
                                    self?.completeSilenty(notification.info, .errorMessageHandling(.decryptionFailed))
                                    return
                                }
                                
                                /// The thread exists and we should have been able to decrypt so show the fallback message
                                self?.handleFailure(
                                    notification.info,
                                    threadVariant: notification.threadVariant,
                                    threadDisplayName: notification.threadDisplayName,
                                    resolution: .errorMessageHandling(.decryptionFailed)
                                )
                                
                            case (let msgError as MessageReceiverError, _, _):
                                self?.handleFailure(
                                    notification.info,
                                    threadVariant: notification.threadVariant,
                                    threadDisplayName: notification.threadDisplayName,
                                    resolution: .errorMessageHandling(msgError)
                                )
                                
                            default:
                                self?.handleFailure(
                                    notification.info,
                                    threadVariant: notification.threadVariant,
                                    threadDisplayName: notification.threadDisplayName,
                                    resolution: .errorOther(error)
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
    
    // MARK: Handle completion
    
    override public func serviceExtensionTimeWillExpire() {
        /// Called just before the extension will be terminated by the system
        completeSilenty(cachedNotificationInfo, .errorTimeout)
    }
    
    private func completeSilenty(_ info: NotificationInfo, _ resolution: NotificationResolution) {
        // This can be called from within database threads so to prevent blocking and weird
        // behaviours make sure to send it to the main thread instead
        // TODO: [Database Relocation] Should be able to remove this
        guard Thread.isMainThread else {
            return DispatchQueue.main.async { [weak self] in
                self?.completeSilenty(info, resolution)
            }
        }
        
        // Ensure we only run this once
        guard _hasCompleted.performUpdateAndMap({ (true, $0) }) == false else { return }
        
        let silentContent: UNMutableNotificationContent = UNMutableNotificationContent()
        
        switch resolution {
            case .ignoreDueToMainAppRunning: break
            default:
                // TODO: [Database Relocation] Need to get the unread count
                break
//                /// Update the app badge in case the unread count changed
//                if
//                    let unreadCount: Int = dependencies[singleton: .storage].read({ [dependencies] db in
//                        try Interaction.fetchAppBadgeUnreadCount(db, using: dependencies)
//                    })
//                {
//                    silentContent.badge = NSNumber(value: unreadCount)
//                }
                
//                dependencies[singleton: .storage].suspendDatabaseAccess()
        }
        
        let duration: CFTimeInterval = (CACurrentMediaTime() - startTime)
        Log.custom(resolution.logLevel, [.cat], "\(resolution) after \(.seconds(duration), unit: .ms), requestId: \(info.requestId).")
        Log.flush()
        Log.reset()
        
        info.contentHandler(silentContent)
    }
    
    private func handleSuccessForIncomingCall(
        _ notification: ProcessedNotification,
        threadVariant: SessionThread.Variant,
        callMessage: CallMessage,
        sender: String,
        sentTimestampMs: UInt64,
        displayNameRetriever: @escaping (String) -> String?
    ) {
        guard Preferences.isCallKitSupported else {
            return handleFailureForVoIP(
                notification,
                threadVariant: threadVariant,
                callMessage: callMessage,
                displayNameRetriever: displayNameRetriever
            )
        }
        
        // stringlint:ignore_start
        let payload: [String: Any] = [
            "uuid": callMessage.uuid,
            "caller": sender,
            "timestamp": sentTimestampMs,
            "contactName": displayNameRetriever(sender)
                .defaulting(to: Profile.truncated(id: sender, threadVariant: threadVariant))
        ]
        // stringlint:ignore_stop
        
        CXProvider.reportNewIncomingVoIPPushPayload(payload) { [weak self, dependencies] error in
            if let error = error {
                Log.error(.cat, "Failed to notify main app of call message: \(error).")
                self?.handleFailureForVoIP(
                    notification,
                    threadVariant: threadVariant,
                    callMessage: callMessage,
                    displayNameRetriever: displayNameRetriever
                )
            }
            else {
                dependencies[defaults: .appGroup, key: .lastCallPreOffer] = Date()
                self?.completeSilenty(notification.info, .successCall)
            }
        }
    }
    
    private func handleFailureForVoIP(
        _ notification: ProcessedNotification,
        threadVariant: SessionThread.Variant,
        callMessage: CallMessage,
        displayNameRetriever: (String) -> String?
    ) {
        let notificationContent = UNMutableNotificationContent()
        notificationContent.userInfo = [ NotificationUserInfoKey.isFromRemote: true ]
        notificationContent.title = Constants.app_name
        notificationContent.body = callMessage.sender
            .map { sender in displayNameRetriever(sender) }
            .map { senderDisplayName in
                "callsIncoming"
                    .put(key: "name", value: senderDisplayName)
                    .localized()
            }
            .defaulting(to: "callsIncomingUnknown".localized())
        
        // TODO: [Database Relocation] Need to get the unread count
//        /// Update the app badge in case the unread count changed
//        if let unreadCount: Int = try? Interaction.fetchAppBadgeUnreadCount(db, using: dependencies) {
//            notificationContent.badge = NSNumber(value: unreadCount)
//        }
        
        let request = UNNotificationRequest(
            identifier: notification.info.requestId,
            content: notificationContent,
            trigger: nil
        )
        let semaphore = DispatchSemaphore(value: 0)
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                Log.error(.cat, "Failed to add notification request for requestId: \(notification.info.requestId) due to error: \(error).")
            }
            semaphore.signal()
        }
        semaphore.wait()
        Log.info(.cat, "Add remote notification request for requestId: \(notification.info.requestId).")
        
        completeSilenty(notification.info, .errorCallFailure)
    }

    private func handleFailure(
        _ info: NotificationInfo,
        threadVariant: SessionThread.Variant?,
        threadDisplayName: String?,
        resolution: NotificationResolution
    ) {
        // This can be called from within database threads so to prevent blocking and weird
        // behaviours make sure to send it to the main thread instead
        // TODO: [Database Relocation] Should be able to remove this
        guard Thread.isMainThread else {
            return DispatchQueue.main.async { [weak self] in
                self?.handleFailure(
                    info,
                    threadVariant: threadVariant,
                    threadDisplayName: threadDisplayName,
                    resolution: resolution
                )
            }
        }
        
        let duration: CFTimeInterval = (CACurrentMediaTime() - startTime)
        let targetThreadVariant: SessionThread.Variant = (threadVariant ?? .contact) /// Fallback to `contact`
        let targetConfig: ConfigDump.Variant = (targetThreadVariant == .contact ? .contacts : .userGroups)
        let notificationSettings: Preferences.NotificationSettings = dependencies
            .mutate(cache: .libSession, config: targetConfig) { config in
                config?.notificationSettings(
                    threadId: info.metadata.accountId,
                    threadVariant: targetThreadVariant,
                    openGroupUrlInfo: nil,  /// Communities current don't support PNs
                )
            }
            .defaulting(to: (.defaultMode(for: targetThreadVariant), .defaultPreviewType, nil))
        Log.error(.cat, "\(resolution) after \(.seconds(duration), unit: .ms), showing generic failure message for message from namespace: \(info.metadata.namespace), requestId: \(info.requestId).")
        
        /// Now we are done with the database, we should suspend it
        if !dependencies[defaults: .appGroup, key: .isMainAppActive] {
            dependencies[singleton: .storage].suspendDatabaseAccess()
        }
        
        /// Clear the logger
        Log.flush()
        Log.reset()
        
        info.content.title = Constants.app_name
        info.content.userInfo = [ NotificationUserInfoKey.isFromRemote: true ]
        
        /// If it's a notification for a group conversation, the notification preferences are right and we have a name for the group
        /// then we should include it in the notification content
        switch (targetThreadVariant, notificationSettings.previewType, threadDisplayName) {
            case (.group, .nameAndPreview, .some(let name)), (.group, .nameNoPreview, .some(let name)),
                (.legacyGroup, .nameAndPreview, .some(let name)), (.legacyGroup, .nameNoPreview, .some(let name)):
                info.content.body = "messageNewYouveGotGroup"
                    .putNumber(1)
                    .put(key: "group_name", value: name)
                    .localized()
                
            default:
                info.content.body = "messageNewYouveGot"
                    .putNumber(1)
                    .localized()
        }
        
        info.contentHandler(info.content)
        hasCompleted = true
    }
}

// MARK: - Convenience

private extension NotificationServiceExtension {
    struct NotificationInfo {
        static let invalid: NotificationInfo = NotificationInfo(
            content: UNMutableNotificationContent(),
            requestId: "N/A", // stringlint:ignore
            contentHandler: { _ in },
            metadata: .invalid,
            data: Data()
        )
        
        let content: UNMutableNotificationContent
        let requestId: String
        let contentHandler: ((UNNotificationContent) -> Void)
        let metadata: PushNotificationAPI.NotificationMetadata
        let data: Data
        
        func with(
            content: UNMutableNotificationContent? = nil,
            requestId: String? = nil,
            contentHandler: ((UNNotificationContent) -> Void)? = nil,
            metadata: PushNotificationAPI.NotificationMetadata? = nil
        ) -> NotificationInfo {
            return NotificationInfo(
                content: (content ?? self.content),
                requestId: (requestId ?? self.requestId),
                contentHandler: (contentHandler ?? self.contentHandler),
                metadata: (metadata ?? self.metadata),
                data: data
            )
        }
    }
    
    typealias ProcessedNotification = (
        info: NotificationInfo,
        processedMessage: ProcessedMessage,
        threadId: String,
        threadVariant: SessionThread.Variant?,
        threadDisplayName: String?
    )
    
    enum NotificationError: Error {
        case notReadyForExtension
        case processingErrorWithFallback(PushNotificationAPI.ProcessResult, PushNotificationAPI.NotificationMetadata)
        case processingError(PushNotificationAPI.ProcessResult, PushNotificationAPI.NotificationMetadata)
        
        @available(*, deprecated, message: "Should be removed as part of the database relocation work once the notification extension no longer needs the database")
        case migration(Error)
        
        @available(*, deprecated, message: "Should be removed as part of the database relocation work once the notification extension no longer needs the database")
        case databaseInvalid
    }
}
