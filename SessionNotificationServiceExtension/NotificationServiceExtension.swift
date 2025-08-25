// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import CallKit
import UserNotifications
import SessionUIKit
import SessionMessagingKit
import SessionNetworkingKit
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
            let mainAppUnreadCount: Int = try performSetup(notificationInfo)
            notificationInfo = notificationInfo.with(mainAppUnreadCount: mainAppUnreadCount)
            notificationInfo = try extractNotificationInfo(notificationInfo)
            try setupGroupIfNeeded(notificationInfo)
            
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

    private func performSetup(_ info: NotificationInfo) throws -> Int {
        Log.info(.cat, "Performing setup for requestId: \(info.requestId).")
        
        // stringlint:ignore_start
        Log.setup(with: Logger(
            primaryPrefix: "NotificationServiceExtension",
            customDirectory: "\(dependencies[singleton: .fileManager].appSharedDataDirectoryPath)/Logs/NotificationExtension",
            using: dependencies
        ))
        LibSession.clearLoggers()
        LibSession.setupLogger(using: dependencies)
        // stringlint:ignore_stop
        
        /// Try to load the `UserMetadata` before doing any further setup (if it doesn't exist then there is no need to continue)
        guard let userMetadata: ExtensionHelper.UserMetadata = dependencies[singleton: .extensionHelper].loadUserMetadata() else {
            throw NotificationError.notReadyForExtension
        }
        
        /// Setup Version Info and Network
        dependencies.warm(cache: .appVersion)
        
        /// Configure the different targets
        SNUtilitiesKit.configure(
            networkMaxFileSize: Network.maxFileSize,
            maxValidImageDimention: ImageDataManager.DataSource.maxValidDimension,
            using: dependencies
        )
        SNMessagingKit.configure(using: dependencies)
        
        /// Cache the users secret key
        dependencies.mutate(cache: .general) {
            $0.setSecretKey(ed25519SecretKey: userMetadata.ed25519SecretKey)
        }
        
        /// Load the `libSession` state into memory using the `extensionHelper`
        let cache: LibSession.Cache = LibSession.Cache(
            userSessionId: userMetadata.sessionId,
            using: dependencies
        )
        dependencies[singleton: .extensionHelper].loadUserConfigState(
            into: cache,
            userSessionId: userMetadata.sessionId,
            userEd25519SecretKey: userMetadata.ed25519SecretKey
        )
        dependencies.set(cache: .libSession, to: cache)
        
        /// The `NotificationServiceExtension` needs custom behaviours for it's notification presenter so set it up here
        ///
        /// **Note:** This **MUST** happen after we have loaded the `libSession` cache as the notification settings are
        /// stored in there
        dependencies.set(singleton: .notificationsManager, to: NSENotificationPresenter(using: dependencies))
        
        return userMetadata.unreadCount
    }
    
    private func setupGroupIfNeeded(_ info: NotificationInfo) throws {
        let loadResult: [ConfigDump.Variant: Bool] = try dependencies.mutate(cache: .libSession) { cache in
            try dependencies[singleton: .extensionHelper].loadGroupConfigStateIfNeeded(
                into: cache,
                swarmPublicKey: info.metadata.accountId,
                userEd25519SecretKey: dependencies[cache: .general].ed25519SecretKey
            )
        }
        
        /// Log the result if it is a notification for a group
        if (try? SessionId(from: info.metadata.accountId).prefix) == .group {
            let resultString: String = ConfigDump.Variant.groupVariants
                .map { "\($0): \(loadResult[$0] ?? false)" }
                .joined(separator: ", ")
            Log.info(.cat, "Setup group \(info.metadata.accountId) config state (\(resultString)) for requestId: \(info.requestId).")
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
                    data: data,
                    mainAppUnreadCount: info.mainAppUnreadCount
                )
                
            default: throw NotificationError.processingError(result, metadata)
        }
    }
    
    private func processNotification(_ info: NotificationInfo) throws -> ProcessedNotification {
        let processedMessage: ProcessedMessage = try MessageReceiver.parse(
            data: info.data,
            origin: .swarm(
                publicKey: info.metadata.accountId,
                namespace: {
                    switch (info.metadata.namespace, (try? SessionId(from: info.metadata.accountId))?.prefix) {
                        /// There was a bug at one point where the metadata would include a `null` value for the namespace
                        /// because the storage server didn't have an explicit `namespace_id` for the
                        /// `revokedRetrievableGroupMessages` namespace
                        ///
                        /// This code tries to work around that issue
                        ///
                        /// **Note:** This issue was present in storage server version `2.10.0` but this work-around should
                        /// be removed once the network has been fully updated with a fix
                        case (.unknown, .group):
                            return .revokedRetrievableGroupMessages
                        
                        default: return info.metadata.namespace
                    }
                }(),
                serverHash: info.metadata.hash,
                serverTimestampMs: info.metadata.createdTimestampMs,
                serverExpirationTimestamp: (
                    (TimeInterval(dependencies[cache: .snodeAPI].currentOffsetTimestampMs() + SnodeReceivedMessage.defaultExpirationMs) / 1000)
                )
            ),
            using: dependencies
        )
        try MessageDeduplication.ensureMessageIsNotADuplicate(processedMessage, using: dependencies)
        
        var threadVariant: SessionThread.Variant?
        var threadDisplayName: String?
        
        switch processedMessage {
            case .invalid: throw MessageReceiverError.invalidMessage
            case .config:
                threadVariant = nil
                threadDisplayName = nil
                
            case .standard(let threadId, let threadVariantVal, _, let messageInfo, _):
                threadVariant = threadVariantVal
                threadDisplayName = dependencies.mutate(cache: .libSession) { cache in
                    cache.conversationDisplayName(
                        threadId: threadId,
                        threadVariant: threadVariantVal,
                        contactProfile: nil,    /// No database access in the NSE
                        visibleMessage: messageInfo.message as? VisibleMessage,
                        openGroupName: nil,     /// Community PNs not currently supported
                        openGroupUrlInfo: nil   /// Community PNs not currently supported
                    )
                }
                
                /// There is some dedupe logic for a `CallMessage` as, depending on the state of the call, we may want to
                /// consider the message a duplicate
                try MessageDeduplication.ensureCallMessageIsNotADuplicate(
                    threadId: threadId,
                    callMessage: messageInfo.message as? CallMessage,
                    using: dependencies
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
        try dependencies.mutate(cache: .libSession) { cache in
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
                afterMerge: { sessionId, variant, config, timestampMs, _ in
                    try updateConfigIfNeeded(
                        cache: cache,
                        config: config,
                        variant: variant,
                        sessionId: sessionId,
                        timestampMs: timestampMs
                    )
                    return nil
                }
            )
        }
        
        /// Write the message to disk via the `extensionHelper` so the main app will have it immediately instead of having to wait
        /// for a poll to return
        do {
            try dependencies[singleton: .extensionHelper].saveMessage(
                SnodeReceivedMessage(
                    snode: nil,
                    publicKey: notification.info.metadata.accountId,
                    namespace: notification.info.metadata.namespace,
                    rawMessage: GetMessagesResponse.RawMessage(
                        base64EncodedDataString: notification.info.data.base64EncodedString(),
                        expirationMs: notification.info.metadata.expirationTimestampMs,
                        hash: notification.info.metadata.hash,
                        timestampMs: serverTimestampMs
                    )
                ),
                threadId: swarmPublicKey,
                isUnread: false,
                isMessageRequest: false
            )
        }
        catch { Log.error(.cat, "Failed to save config message to disk: \(error).") }
        
        /// Since we successfully handled the message we should now create the dedupe file for the message so we don't
        /// show duplicate PNs
        try MessageDeduplication.createDedupeFile(notification.processedMessage, using: dependencies)
        
        /// No notification should be shown for config messages so we can just succeed silently here
        completeSilenty(notification.info, .success(notification.info.metadata))
    }
    
    private func updateConfigIfNeeded(
        cache: LibSessionCacheType,
        config: LibSession.Config?,
        variant: ConfigDump.Variant,
        sessionId: SessionId,
        timestampMs: Int64
    ) throws {
        guard cache.configNeedsDump(config) else {
            return dependencies[singleton: .extensionHelper].refreshDumpModifiedDate(
                sessionId: sessionId,
                variant: variant
            )
        }
        
        /// Update the replicated extension config dump (this way any subsequent push notifications will use the correct
        /// data - eg. group encryption keys)
        try dependencies[singleton: .extensionHelper].replicate(
            dump: cache.createDump(
                config: config,
                for: variant,
                sessionId: sessionId,
                timestampMs: timestampMs
            ),
            replaceExisting: true
        )
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
        
        /// No need to check blinded ids as Communities currently don't support PNs
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let currentUserSessionIds: Set<String> = [userSessionId.hexString]
        
        /// Define the `displayNameRetriever` so it can be reused
        let displayNameRetriever: (String, Bool) -> String? = { [dependencies] sessionId, isInMessageBody in
            (dependencies
                .mutate(cache: .libSession) { cache in
                    cache.profile(
                        contactId: sessionId,
                        threadId: threadId,
                        threadVariant: threadVariant,
                        visibleMessage: (messageInfo.message as? VisibleMessage)
                    )
                }?
                .displayName(
                    for: threadVariant,
                    suppressId: !isInMessageBody  /// Don't want to show the id in a PN unless it's part of the body
                ))
                .defaulting(to: sessionId.truncated())
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
            
            /// The invite control message for `group` conversations can result in a member who was kicked from a group
            /// being re-added so we should handle that case (as it could result in the user starting to get valid notifications again)
            ///
            /// Otherwise just save the message to disk
            case let inviteMessage as GroupUpdateInviteMessage:
                try MessageReceiver.validateGroupInvite(message: inviteMessage, using: dependencies)
                try handleGroupInviteOrPromotion(
                    notification,
                    groupSessionId: inviteMessage.groupSessionId,
                    groupName: inviteMessage.groupName,
                    memberAuthData: inviteMessage.memberAuthData,
                    groupIdentitySeed: nil,
                    proto: proto,
                    messageInfo: messageInfo,
                    currentUserSessionIds: currentUserSessionIds,
                    displayNameRetriever: displayNameRetriever
                )
                return
            
            /// The promote control message for `group` conversations can result in a member who was kicked from a group
            /// being re-added so we should handle that case (as it could result in the user starting to get valid notifications again)
            ///
            /// Otherwise just save the message to disk
            case let promoteMessage as GroupUpdatePromoteMessage:
                guard
                    let groupIdentityKeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                        .ed25519KeyPair(seed: Array(promoteMessage.groupIdentitySeed))
                    )
                else { throw MessageReceiverError.invalidMessage }
                
                try handleGroupInviteOrPromotion(
                    notification,
                    groupSessionId: SessionId(.group, publicKey: groupIdentityKeyPair.publicKey),
                    groupName: promoteMessage.groupName,
                    memberAuthData: nil,
                    groupIdentitySeed: promoteMessage.groupIdentitySeed,
                    proto: proto,
                    messageInfo: messageInfo,
                    currentUserSessionIds: currentUserSessionIds,
                    displayNameRetriever: displayNameRetriever
                )
                return
                
            /// The `kickedMessage` for a `group` conversation will result in the credentials for the group being removed and
            /// if the device receives subsequent notifications for the group which fail to decrypt (due to key rotation after being kicked)
            /// then they will fail silently instead of using the fallback notification
            case let libSessionMessage as LibSessionMessage:
                let info: [MessageReceiver.LibSessionMessageInfo] = try MessageReceiver.decryptLibSessionMessage(
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: libSessionMessage,
                    using: dependencies
                )
                
                try info.forEach { senderSessionId, domain, plaintext in
                    switch domain {
                        case LibSession.Crypto.Domain.kickedMessage:
                            /// Ensure the `groupKicked` message was valid before continuing
                            try LibSessionMessage.validateGroupKickedMessage(
                                plaintext: plaintext,
                                userSessionId: userSessionId,
                                groupSessionId: senderSessionId,
                                using: dependencies
                            )
                            
                            /// Mark the group as kicked and save the updated config dump
                            try dependencies.mutate(cache: .libSession) { cache in
                                try cache.markAsKicked(groupSessionIds: [senderSessionId.hexString])
                                
                                guard let config: LibSession.Config = cache.config(for: .userGroups, sessionId: userSessionId) else {
                                    return
                                }
                                
                                try updateConfigIfNeeded(
                                    cache: cache,
                                    config: config,
                                    variant: .userGroups,
                                    sessionId: userSessionId,
                                    timestampMs: (
                                        libSessionMessage.sentTimestampMs.map { Int64($0) } ??
                                        Int64(dependencies.dateNow.timeIntervalSince1970 * 1000)
                                    )
                                )
                            }
                            
                        default: Log.error(.messageReceiver, "Received libSession encrypted message with unsupported domain: \(domain)")
                    }
                }
                
                /// Save the message and generate any deduplication files needed
                try saveMessage(
                    notification,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    isMessageRequest: dependencies.mutate(cache: .libSession) { libSession in
                        libSession.isMessageRequest(threadId: threadId, threadVariant: threadVariant)
                    },
                    messageInfo: messageInfo,
                    currentUserSessionIds: currentUserSessionIds
                )
                completeSilenty(notification.info, .success(notification.info.metadata))
                return
                
            case let callMessage as CallMessage:
                switch callMessage.kind {
                    case .preOffer: Log.info(.calls, "Received pre-offer message with uuid: \(callMessage.uuid).")
                    case .offer: Log.info(.calls, "Received offer message.")
                    case .answer: Log.info(.calls, "Received answer message.")
                    case .endCall: Log.info(.calls, "Received end call message.")
                    case .provisionalAnswer, .iceCandidates: break
                }
                
                let areCallsEnabled: Bool = dependencies.mutate(cache: .libSession) { cache in
                    cache.get(.areCallsEnabled)
                }
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
                
                /// Handle the call as needed
                switch ((areCallsEnabled && hasMicrophonePermission), isCallOngoing, callMessage.kind) {
                    case (false, _, _):
                        /// Update the `CallMessage.state` value so the correct notification logic can occur
                        callMessage.state = (areCallsEnabled ? .permissionDeniedMicrophone : .permissionDenied)
                        
                    case (true, true, _):
                        guard let sender: String = callMessage.sender else {
                            throw MessageReceiverError.invalidMessage
                        }
                        guard
                            let userEdKeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                                .ed25519KeyPair(seed: dependencies[cache: .general].ed25519Seed)
                            )
                        else { throw SnodeAPIError.noKeyPair }
                        
                        Log.info(.calls, "Sending end call message because there is an ongoing call.")
                        /// Update the `CallMessage.state` value so the correct notification logic can occur
                        callMessage.state = .missed
                        
                        let semaphore: DispatchSemaphore = DispatchSemaphore(value: 0)
                        try MessageReceiver
                            .sendIncomingCallOfferInBusyStateResponse(
                                threadId: threadId,
                                message: callMessage,
                                disappearingMessagesConfiguration: dependencies.mutate(cache: .libSession) { cache in
                                    cache.disappearingMessagesConfig(threadId: threadId, threadVariant: threadVariant)
                                },
                                authMethod: Authentication.standard(
                                    sessionId: SessionId(.standard, hex: sender),
                                    ed25519PublicKey: userEdKeyPair.publicKey,
                                    ed25519SecretKey: userEdKeyPair.secretKey
                                ),
                                onEvent: { _ in },  /// Do nothing for any of the message sending events
                                using: dependencies
                            )
                            .send(using: dependencies)
                            .sinkUntilComplete(
                                receiveCompletion: { result in
                                    switch result {
                                        case .finished: semaphore.signal()
                                        case .failure(let error):
                                            Log.error(.cat, "Failed to send incoming call offer in busy state response: \(error)")
                                            semaphore.signal()
                                    }
                                }
                            )
                        let result = semaphore.wait(timeout: .now() + .seconds(Int(Network.defaultTimeout)))
                        
                        switch (result, hasCompleted) {
                            case (.timedOut, _), (_, true): throw NotificationError.timeout
                            case (.success, false): break    /// Show the notification and write the message to disk
                        }
                        
                    case (true, false, .preOffer):
                        let isMessageRequest: Bool = dependencies.mutate(cache: .libSession) { libSession in
                            libSession.isMessageRequest(threadId: threadId, threadVariant: threadVariant)
                        }
                        
                        guard
                            let sender: String = callMessage.sender,
                            let sentTimestampMs: UInt64 = callMessage.sentTimestampMs,
                            threadVariant == .contact,
                            !isMessageRequest
                        else { throw MessageReceiverError.invalidMessage }
                        
                        /// Save the message and generate any deduplication files needed
                        try saveMessage(
                            notification,
                            threadId: threadId,
                            threadVariant: threadVariant,
                            isMessageRequest: isMessageRequest,
                            messageInfo: messageInfo,
                            currentUserSessionIds: currentUserSessionIds
                        )
                        
                        /// Handle the message as a successful call
                        return handleSuccessForIncomingCall(
                            notification,
                            threadVariant: threadVariant,
                            callMessage: callMessage,
                            sender: sender,
                            sentTimestampMs: sentTimestampMs,
                            displayNameRetriever: displayNameRetriever
                        )
                        
                    default: break  /// Send all other cases through the standard notification handling
                }
                
            case is VisibleMessage: break
            
            /// For any other message we don't have any custom handling (and don't want to show a notification) so just save these
            /// messages to disk to be processed on next launch (letting the main app do any error handling) and just complete silently
            default:
                try saveMessage(
                    notification,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    isMessageRequest: dependencies.mutate(cache: .libSession) { libSession in
                        libSession.isMessageRequest(threadId: threadId, threadVariant: threadVariant)
                    },
                    messageInfo: messageInfo,
                    currentUserSessionIds: currentUserSessionIds
                )
                completeSilenty(notification.info, .success(notification.info.metadata))
                return
        }
        
        /// Save and notify for the message
        try saveAndNotify(
            notification,
            threadId: threadId,
            threadVariant: threadVariant,
            proto: proto,
            messageInfo: messageInfo,
            currentUserSessionIds: currentUserSessionIds,
            displayNameRetriever: displayNameRetriever
        )
        
        /// Since we succeeded we can complete silently
        completeSilenty(notification.info, .success(notification.info.metadata))
    }
    
    private func handleGroupInviteOrPromotion(
        _ notification: ProcessedNotification,
        groupSessionId: SessionId,
        groupName: String,
        memberAuthData: Data?,
        groupIdentitySeed: Data?,
        proto: SNProtoContent,
        messageInfo: MessageReceiveJob.Details.MessageInfo,
        currentUserSessionIds: Set<String>,
        displayNameRetriever: (String, Bool) -> String?
    ) throws {
        typealias GroupInfo = (
            wasMessageRequest: Bool,
            isMessageRequest: Bool,
            wasKickedFromGroup: Bool
        )
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let groupInfo: GroupInfo = try dependencies.mutate(cache: .libSession) { cache in
            let groupIdentityKeyPair: KeyPair? = groupIdentitySeed.map {
                dependencies[singleton: .crypto].generate(.ed25519KeyPair(seed: Array($0)))
            }
            let wasKickedFromGroup: Bool = cache.wasKickedFromGroup(groupSessionId: groupSessionId)
            let wasMessageRequest: Bool = cache.isMessageRequest(threadId: groupSessionId.hexString, threadVariant: .group)
            
            guard
                (memberAuthData != nil || groupIdentityKeyPair != nil),
                let sentTimestampMs: UInt64 = messageInfo.message.sentTimestampMs,
                let config: LibSession.Config = cache.config(for: .userGroups, sessionId: userSessionId)
            else { return (wasMessageRequest, wasMessageRequest, wasKickedFromGroup) }
            
            /// Add the group credentials key to the `userGroups` config (only include the name if this is a message request as we
            /// don't want to override a value we already have stored)
            try LibSession.upsert(
                groups: [
                    LibSession.GroupUpdateInfo(
                        groupSessionId: groupSessionId.hexString,
                        groupIdentityPrivateKey: groupIdentityKeyPair.map { Data($0.secretKey) },
                        name: (wasMessageRequest ? groupName : nil),
                        authData: memberAuthData,
                        joinedAt: (wasMessageRequest ? TimeInterval(sentTimestampMs / 1000) : nil),
                        invited: (wasMessageRequest ? true : nil)
                    )
                ],
                in: config,
                using: dependencies
            )
            
            /// If we were previously marked as kicked from the group then we need to explicitly mark the user as invited again to
            /// clear the kicked state
            if wasKickedFromGroup {
                try cache.markAsInvited(groupSessionIds: [groupSessionId.hexString])
            }
            
            /// Save the updated `userGroups` config
            try updateConfigIfNeeded(
                cache: cache,
                config: config,
                variant: .userGroups,
                sessionId: userSessionId,
                timestampMs: Int64(sentTimestampMs)
            )
            
            /// If the invite should be auto-approved then do so
            let senderIsApproved: Bool? = messageInfo.message.sender.map { sender in
                guard !dependencies[feature: .updatedGroupsDisableAutoApprove] else { return false }
                
                return cache.isContactApproved(contactId: sender)
            }
            
            if senderIsApproved == true {
                try LibSession.upsert(
                    groups: [
                        LibSession.GroupUpdateInfo(
                            groupSessionId: groupSessionId.hexString,
                            invited: false
                        )
                    ],
                    in: config,
                    using: dependencies
                )
            }
            
            /// If we were given a `groupIdentityPrivateKey` and have a `groupKeys` config then we also need to
            /// update it with the admin key
            guard
                let groupIdentitySeed: Data = groupIdentitySeed,
                let groupKeysConfig: LibSession.Config = cache.config(for: .groupKeys, sessionId: groupSessionId)
            else { return (wasMessageRequest, (wasMessageRequest && senderIsApproved != true), wasKickedFromGroup) }
            
            try cache.loadAdminKey(
                groupIdentitySeed: groupIdentitySeed,
                groupSessionId: groupSessionId
            )
            try updateConfigIfNeeded(
                cache: cache,
                config: groupKeysConfig,
                variant: .groupKeys,
                sessionId: groupSessionId,
                timestampMs: Int64(sentTimestampMs)
            )
            
            return (wasMessageRequest, (wasMessageRequest && senderIsApproved != true), wasKickedFromGroup)
        }
        
        switch (groupInfo.wasKickedFromGroup, groupInfo.wasMessageRequest) {
            /// If the user was previously kicked from the group then we don't want to show a notification (as they aren't _really_ invited
            /// in this case, and it's more likely they were mistakenly removed and re-added when this occurs)
            ///
            /// Additionally, if the group isn't a message request (ie. is currently in the "invited" state, even prior to auto-approval) then
            /// we don't want to show a notification for any "invite" or "promote" messages as the user should get proper notifications
            /// via the group itself for anything that is relevant
            case (true, _), (_, false):
                try saveMessage(
                    notification,
                    threadId: groupSessionId.hexString,
                    threadVariant: .group,
                    isMessageRequest: groupInfo.isMessageRequest,
                    messageInfo: messageInfo,
                    currentUserSessionIds: currentUserSessionIds
                )
                
            /// Otherwise we want to save the message and trigger the notification
            case (false, true):
                try saveAndNotify(
                    notification,
                    threadId: groupSessionId.hexString,
                    threadVariant: .group,
                    proto: proto,
                    messageInfo: messageInfo,
                    currentUserSessionIds: currentUserSessionIds,
                    displayNameRetriever: displayNameRetriever
                )
        }
        
//        /// If the group was auto-approved then we also want to try to subscribe for push notifications for the group (if we can get the cached push token)
//        if
//            groupInfo.wasMessageRequest && !groupInfo.isMessageRequest,
//            let token: String = dependencies[defaults: .standard, key: .deviceToken]
//        {
//            // TODO: [Database Relocation] Need to de-database the 'preparedSubscribe' call for this to work (neeeds the AuthMethod logic to be de-databased)
//            /// Since this is an API call we need to wait for it to complete before we trigger the `completeSilently` logic
//            Log.info(.cat, "Group invitation was auto-approved, attempting to subscribe for PNs.")
//            try? PushNotificationAPI
//                .preparedSubscribe(
//                    db,
//                    token: Data(hex: token),
//                    sessionIds: [groupSessionId],
//                    using: dependencies
//                )
//                .send(using: dependencies)
//                .sinkUntilComplete(
//                    receiveCompletion: { _ in
//                        completeSilenty(notification.info, .success(notification.info.metadata))
//                    }
//                )
//            return
//        }
        
        /// Since we succeeded we can complete silently
        completeSilenty(notification.info, .success(notification.info.metadata))
    }
    
    private func saveMessage(
        _ notification: ProcessedNotification,
        threadId: String,
        threadVariant: SessionThread.Variant,
        isMessageRequest: Bool,
        messageInfo: MessageReceiveJob.Details.MessageInfo,
        currentUserSessionIds: Set<String>
    ) throws {
        /// Write the message to disk via the `extensionHelper` so the main app will have it immediately instead of having to wait
        /// for a poll to return
        do {
            guard let sentTimestamp: Int64 = messageInfo.message.sentTimestampMs.map(Int64.init) else {
                throw MessageReceiverError.invalidMessage
            }
            
            try dependencies[singleton: .extensionHelper].saveMessage(
                SnodeReceivedMessage(
                    snode: nil,
                    publicKey: notification.info.metadata.accountId,
                    namespace: notification.info.metadata.namespace,
                    rawMessage: GetMessagesResponse.RawMessage(
                        base64EncodedDataString: notification.info.data.base64EncodedString(),
                        expirationMs: notification.info.metadata.expirationTimestampMs,
                        hash: notification.info.metadata.hash,
                        timestampMs: Int64(sentTimestamp)
                    )
                ),
                threadId: threadId,
                isUnread: (
                    /// Ensure the type of message can actually be unread
                    Interaction.Variant(
                        message: messageInfo.message,
                        currentUserSessionIds: currentUserSessionIds
                    )?.canBeUnread == true &&
                    /// Ensure the message hasn't been read on another device
                    dependencies.mutate(cache: .libSession, { cache in
                        !cache.timestampAlreadyRead(
                            threadId: threadId,
                            threadVariant: threadVariant,
                            timestampMs: (messageInfo.message.sentTimestampMs.map { Int64($0) } ?? 0),  /// Default to unread
                            openGroupUrlInfo: nil  /// Communities currently don't support PNs
                        )
                    }) &&
                    {
                        /// If it's not a `CallMessage` or is a `preOffer` than it can be unread
                        guard
                            let callMessage: CallMessage = messageInfo.message as? CallMessage,
                            callMessage.kind != .preOffer
                        else { return true }
                        
                        /// If there is a dedupe record for the `preOffer` of this call, or a dedupe record for the call in general
                        /// then it would have already incremented the unread count so this message shouldn't count
                        do {
                            try MessageDeduplication.ensureMessageIsNotADuplicate(
                                threadId: threadId,
                                uniqueIdentifier: callMessage.preOfferDedupeIdentifier,
                                using: dependencies
                            )
                            try MessageDeduplication.ensureMessageIsNotADuplicate(
                                threadId: threadId,
                                uniqueIdentifier: callMessage.preOfferDedupeIdentifier,
                                using: dependencies
                            )
                        }
                        catch { return false }
                        
                        /// Otherwise the call should increment the count
                        return true
                    }()
                ),
                isMessageRequest: isMessageRequest
            )
        }
        catch { Log.error(.cat, "Failed to save message to disk: \(error).") }
        
        /// Since we successfully handled the message we should now create the dedupe file for the message so we don't
        /// show duplicate PNs
        try MessageDeduplication.createDedupeFile(notification.processedMessage, using: dependencies)
        try MessageDeduplication.createCallDedupeFilesIfNeeded(
            threadId: threadId,
            callMessage: messageInfo.message as? CallMessage,
            using: dependencies
        )
    }
    
    private func saveAndNotify(
        _ notification: ProcessedNotification,
        threadId: String,
        threadVariant: SessionThread.Variant,
        proto: SNProtoContent,
        messageInfo: MessageReceiveJob.Details.MessageInfo,
        currentUserSessionIds: Set<String>,
        displayNameRetriever: (String, Bool) -> String?
    ) throws {
        /// Since we are going to save the message and generate deduplication files we need to determine whether we would want
        /// to show the message in case it is a message request (this is done by checking if there are already any dedupe records
        /// for this conversation so needs to be done before they are generated)
        let isMessageRequest: Bool = dependencies.mutate(cache: .libSession) { cache in
            cache.isMessageRequest(
                threadId: threadId,
                threadVariant: threadVariant
            )
        }
        let shouldShowForMessageRequest: Bool = (!isMessageRequest ? false :
            !dependencies[singleton: .extensionHelper].hasDedupeRecordSinceLastCleared(threadId: threadId)
        )
        
        /// Save the message and generate any deduplication files needed
        try saveMessage(
            notification,
            threadId: threadId,
            threadVariant: threadVariant,
            isMessageRequest: isMessageRequest,
            messageInfo: messageInfo,
            currentUserSessionIds: currentUserSessionIds
        )
        
        /// Try to show a notification for the message
        try dependencies[singleton: .notificationsManager].notifyUser(
            cat: .cat,
            message: messageInfo.message,
            threadId: threadId,
            threadVariant: threadVariant,
            interactionIdentifier: notification.info.metadata.hash,
            interactionVariant: Interaction.Variant(
                message: messageInfo.message,
                currentUserSessionIds: currentUserSessionIds
            ),
            attachmentDescriptionInfo: proto.dataMessage?.attachments.map { attachment in
                Attachment.DescriptionInfo(id: "", proto: attachment)
            },
            openGroupUrlInfo: nil,  /// Communities currently don't support PNs
            applicationState: .background,
            extensionBaseUnreadCount: notification.info.mainAppUnreadCount,
            currentUserSessionIds: currentUserSessionIds,
            displayNameRetriever: displayNameRetriever,
            groupNameRetriever: { threadId, threadVariant in
                switch threadVariant {
                    case .group:
                        let groupId: SessionId = SessionId(.group, hex: threadId)
                        return dependencies.mutate(cache: .libSession) { cache in
                            cache.groupName(groupSessionId: groupId)
                        }
                        
                    case .community: return nil  /// Communities currently don't support PNs
                    default: return nil
                }
            },
            shouldShowForMessageRequest: { shouldShowForMessageRequest }
        )
    }
    
    private func handleError(
        _ error: Error,
        info: NotificationInfo,
        processedNotification: ProcessedNotification?,
        contentHandler: ((UNNotificationContent) -> Void)
    ) {
        switch (error, (try? SessionId(from: info.metadata.accountId))?.prefix, info.metadata.namespace.isConfigNamespace) {
            case (NotificationError.timeout, _, _):
                self.completeSilenty(info, .errorTimeout)
            
            case (NotificationError.notReadyForExtension, _, _):
                self.completeSilenty(info, .errorNotReadyForExtensions)
                
            case (NotificationError.processingErrorWithFallback(let result, let errorMetadata), _, _):
                self.handleFailure(
                    info.with(metadata: errorMetadata),
                    threadId: processedNotification?.threadId,
                    threadVariant: processedNotification?.threadVariant,
                    threadDisplayName: processedNotification?.threadDisplayName,
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
            
            case (MessageReceiverError.selfSend, _, _):
                self.completeSilenty(info, .ignoreDueToSelfSend)
                
            case (MessageReceiverError.noGroupKeyPair, _, _):
                self.completeSilenty(info, .errorLegacyPushNotification)
                
            case (MessageReceiverError.outdatedMessage, _, _):
                self.completeSilenty(info, .ignoreDueToOutdatedMessage)
                
            case (MessageReceiverError.ignorableMessage, _, _):
                self.completeSilenty(info, .ignoreDueToRequiresNoNotification)
                
            case (MessageReceiverError.ignorableMessageRequestMessage, _, _):
                self.completeSilenty(info, .ignoreDueToMessageRequest)
                
            case (MessageReceiverError.duplicateMessage, _, _):
                self.completeSilenty(info, .ignoreDueToDuplicateMessage)
                
            case (MessageReceiverError.duplicatedCall, _, _):
                self.completeSilenty(info, .ignoreDueToDuplicateCall)
                
            /// If it was a `decryptionFailed` error, but it was for a config namespace then just fail silently (don't
            /// want to show the fallback notification in this case)
            case (MessageReceiverError.decryptionFailed, _, true):
                self.completeSilenty(info, .errorMessageHandling(.decryptionFailed, info.metadata))
                
            /// If it was a `decryptionFailed` error for a group conversation and the group doesn't exist or
            /// doesn't have auth info (ie. group destroyed or member kicked), then just fail silently (don't want
            /// to show the fallback notification in these cases)
            case (MessageReceiverError.decryptionFailed, .group, _):
                guard
                    let threadId: String = processedNotification?.threadId,
                    dependencies.mutate(cache: .libSession, { cache in
                        cache.hasCredentials(groupSessionId: SessionId(.group, hex: threadId))
                    })
                else {
                    self.completeSilenty(info, .errorMessageHandling(.decryptionFailed, info.metadata))
                    return
                }
                
                /// The thread exists and we should have been able to decrypt so show the fallback message
                self.handleFailure(
                    info,
                    threadId: processedNotification?.threadId,
                    threadVariant: processedNotification?.threadVariant,
                    threadDisplayName: processedNotification?.threadDisplayName,
                    resolution: .errorMessageHandling(.decryptionFailed, info.metadata)
                )
                
            case (let msgError as MessageReceiverError, _, _):
                self.handleFailure(
                    info,
                    threadId: processedNotification?.threadId,
                    threadVariant: processedNotification?.threadVariant,
                    threadDisplayName: processedNotification?.threadDisplayName,
                    resolution: .errorMessageHandling(msgError, info.metadata)
                )
                
            default:
                self.handleFailure(
                    info,
                    threadId: processedNotification?.threadId,
                    threadVariant: processedNotification?.threadVariant,
                    threadDisplayName: processedNotification?.threadDisplayName,
                    resolution: .errorOther(error)
                )
        }
    }
    
    // MARK: Handle completion
    
    override public func serviceExtensionTimeWillExpire() {
        /// Called just before the extension will be terminated by the system
        completeSilenty(cachedNotificationInfo, .errorTimeout)
    }
    
    private func completeSilenty(_ info: NotificationInfo, _ resolution: NotificationResolution) {
        // Ensure we only run this once
        guard _hasCompleted.performUpdateAndMap({ (true, $0) }) == false else { return }
        
        let silentContent: UNMutableNotificationContent = UNMutableNotificationContent()
        
        switch resolution {
            case .ignoreDueToMainAppRunning: break
            default:
                /// Since we will have already written the message to disk at this stage we can just add the number of unread message files
                /// directly to the `mainAppUnreadCount` in order to get the updated unread count
                if let unreadPendingMessageCount: Int = dependencies[singleton: .extensionHelper].unreadMessageCount() {
                    silentContent.badge = NSNumber(value: info.mainAppUnreadCount + unreadPendingMessageCount)
                }
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
        displayNameRetriever: @escaping (String, Bool) -> String?
    ) {
        guard Preferences.isCallKitSupported else {
            return handleFailureForVoIP(
                notification,
                threadVariant: threadVariant,
                callMessage: callMessage,
                displayNameRetriever: displayNameRetriever
            )
        }
        
        let payload: [String: Any] = [
            VoipPayloadKey.uuid.rawValue: callMessage.uuid,
            VoipPayloadKey.caller.rawValue: sender,
            VoipPayloadKey.timestamp.rawValue: sentTimestampMs,
            VoipPayloadKey.contactName.rawValue: displayNameRetriever(sender, false)
                .defaulting(to: sender.truncated(threadVariant: threadVariant))
        ]
        
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
        displayNameRetriever: (String, Bool) -> String?
    ) {
        let content: UNMutableNotificationContent = UNMutableNotificationContent()
        content.userInfo = [ NotificationUserInfoKey.isFromRemote: true ]
        content.title = Constants.app_name
        content.body = callMessage.sender
            .map { sender in displayNameRetriever(sender, false) }
            .map { senderDisplayName in
                "callsIncoming"
                    .put(key: "name", value: senderDisplayName)
                    .localized()
            }
            .defaulting(to: "callsIncomingUnknown".localized())
        
        /// Since we will have already written the message to disk at this stage we can just add the number of unread message files
        /// directly to the `mainAppUnreadCount` in order to get the updated unread count
        if let unreadPendingMessageCount: Int = dependencies[singleton: .extensionHelper].unreadMessageCount() {
            content.badge = NSNumber(value: notification.info.mainAppUnreadCount + unreadPendingMessageCount)
        }
        
        let request = UNNotificationRequest(
            identifier: notification.info.requestId,
            content: content,
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
        threadId: String?,
        threadVariant: SessionThread.Variant?,
        threadDisplayName: String?,
        resolution: NotificationResolution
    ) {
        let duration: CFTimeInterval = (CACurrentMediaTime() - startTime)
        let targetThreadVariant: SessionThread.Variant = (threadVariant ?? .contact) /// Fallback to `contact`
        let notificationSettings: Preferences.NotificationSettings = dependencies[singleton: .notificationsManager].settings(
            threadId: info.metadata.accountId,
            threadVariant: targetThreadVariant
        )
        let hasOrigin: Bool = resolution.description.contains(info.metadata.messageOriginString)
        Log.error(.cat, "\(resolution) after \(.seconds(duration), unit: .ms), showing generic failure message\(hasOrigin ? "" : " for message from \(info.metadata.messageOriginString)"), requestId: \(info.requestId).")
        
        /// Clear the logger
        Log.flush()
        Log.reset()
        
        /// Attach the metadata to the notification (if we got far enough to get it - use the explicit `threadVariant` provided, otherwise
        /// try to infer it based on the `accountId` or `threadId` from processing the notification)
        ///
        /// **Note:** All `1-to-1` notifications will have the current users session id for the `accountId` value so only attach
        /// the `accountId` as the `threadId` for group notifications (for which it'll _actually_ be the group id)
        info.content.title = Constants.app_name
        info.content.userInfo = {
            switch (info.metadata, threadId, try? SessionId.Prefix(from: info.metadata.accountId)) {
                case (_, .some(let threadId), _):
                    return dependencies[singleton: .notificationsManager].notificationUserInfo(
                        threadId: threadId,
                        threadVariant: (
                            threadVariant ??
                            ((try? SessionId.Prefix(from: threadId)) == .group ? .group : .contact)
                        )
                     )
                
                case (.invalid, _, .group):
                    return dependencies[singleton: .notificationsManager].notificationUserInfo(
                        threadId: info.metadata.accountId,
                        threadVariant: .group
                     )
                
                case (.invalid, _, _), (_, .none, _):
                    return [ NotificationUserInfoKey.isFromRemote: true ]
            }
        }()
        
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
            data: Data(),
            mainAppUnreadCount: 0
        )
        
        let content: UNMutableNotificationContent
        let requestId: String
        let contentHandler: ((UNNotificationContent) -> Void)
        let metadata: PushNotificationAPI.NotificationMetadata
        let data: Data
        let mainAppUnreadCount: Int
        
        func with(
            requestId: String? = nil,
            content: UNMutableNotificationContent? = nil,
            contentHandler: ((UNNotificationContent) -> Void)? = nil,
            metadata: PushNotificationAPI.NotificationMetadata? = nil,
            mainAppUnreadCount: Int? = nil
        ) -> NotificationInfo {
            return NotificationInfo(
                content: (content ?? self.content),
                requestId: (requestId ?? self.requestId),
                contentHandler: (contentHandler ?? self.contentHandler),
                metadata: (metadata ?? self.metadata),
                data: data,
                mainAppUnreadCount: (mainAppUnreadCount ?? self.mainAppUnreadCount)
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
        case timeout
    }
}
