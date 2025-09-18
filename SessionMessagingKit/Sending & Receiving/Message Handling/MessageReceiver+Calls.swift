// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import AVFAudio
import GRDB
import WebRTC
import SessionUtilitiesKit
import SessionNetworkingKit

// MARK: - Log.Category

public extension Log.Category {
    static let calls: Log.Category = .create("Calls", defaultLevel: .info)
}

// MARK: - MessageReceiver

extension MessageReceiver {
    public static func handleCallMessage(
        _ db: ObservingDatabase,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: CallMessage,
        suppressNotifications: Bool,
        using dependencies: Dependencies
    ) throws -> InsertedInteractionInfo? {
        // Only support calls from contact threads
        guard threadVariant == .contact else { throw MessageReceiverError.invalidMessage }
        
        switch (message.kind, message.state) {
            case (.preOffer, _):
                return try MessageReceiver.handleNewCallMessage(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    suppressNotifications: suppressNotifications,
                    using: dependencies
                )
            
            case (.offer, _): MessageReceiver.handleOfferCallMessage(db, message: message, using: dependencies)
            case (.answer, _): MessageReceiver.handleAnswerCallMessage(db, message: message, using: dependencies)
            case (.provisionalAnswer, _): break // TODO: [CALLS] Implement
                
            case (.iceCandidates(let sdpMLineIndexes, let sdpMids), _):
                dependencies[singleton: .callManager].handleICECandidates(
                    message: message,
                    sdpMLineIndexes: sdpMLineIndexes,
                    sdpMids: sdpMids
                )
            
            case (.endCall, .missed):
                return try MessageReceiver.handleIncomingCallOfferInBusyState(
                    db,
                    threadId: threadId,
                    threadVariant: threadVariant,
                    message: message,
                    suppressNotifications: suppressNotifications,
                    using: dependencies
                )
                
            case (.endCall, _): MessageReceiver.handleEndCallMessage(db, message: message, using: dependencies)
        }
        
        return nil
    }
    
    // MARK: - Specific Handling
    
    private static func handleNewCallMessage(
        _ db: ObservingDatabase,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: CallMessage,
        suppressNotifications: Bool,
        using dependencies: Dependencies
    ) throws -> InsertedInteractionInfo? {
        Log.info(.calls, "Received pre-offer message with uuid: \(message.uuid).")
        
        // Determine whether the app is active based on the prefs rather than the UIApplication state to avoid
        // requiring main-thread execution
        let isMainAppActive: Bool = dependencies[defaults: .appGroup, key: .isMainAppActive]
        
        // It is enough just ignoring the pre offers, other call messages
        // for this call would be dropped because of no Session call instance
        guard
            dependencies[singleton: .appContext].isMainApp,
            let sender: String = message.sender,
            dependencies.mutate(cache: .libSession, { cache in
                !cache.isMessageRequest(threadId: threadId, threadVariant: threadVariant)
            })
        else { throw MessageReceiverError.invalidMessage }
        guard let timestampMs = message.sentTimestampMs, TimestampUtils.isWithinOneMinute(timestampMs: timestampMs) else {
            // Add missed call message for call offer messages from more than one minute
            Log.info(.calls, "Got an expired call offer message with uuid: \(message.uuid). Sent at \(message.sentTimestampMs ?? 0), now is \(Date().timeIntervalSince1970 * 1000)")
            if let interaction: Interaction = try MessageReceiver.insertCallInfoMessage(db, threadId: threadId, threadVariant: threadVariant, for: message, state: .missed, using: dependencies), let interactionId: Int64 = interaction.id {
                let thread: SessionThread = try SessionThread.upsert(
                    db,
                    id: sender,
                    variant: .contact,
                    values: .existingOrDefault,
                    using: dependencies
                )
                
                if !suppressNotifications && !interaction.wasRead {
                    /// Update the `CallMessage.state` value so the correct notification logic can occur
                    message.state = .missed
                    
                    try? dependencies[singleton: .notificationsManager].notifyUser(
                        cat: .messageReceiver,
                        message: message,
                        threadId: thread.id,
                        threadVariant: thread.variant,
                        interactionIdentifier: (interaction.serverHash ?? "\(interactionId)"),
                        interactionVariant: interaction.variant,
                        attachmentDescriptionInfo: nil,
                        openGroupUrlInfo: nil,
                        applicationState: (isMainAppActive ? .active : .background),
                        extensionBaseUnreadCount: nil,
                        currentUserSessionIds: [dependencies[cache: .general].sessionId.hexString],
                        displayNameRetriever: { sessionId, _ in
                            Profile.displayNameNoFallback(
                                db,
                                id: sessionId,
                                threadVariant: thread.variant
                            )
                        },
                        groupNameRetriever: { threadId, threadVariant in
                            switch threadVariant {
                                case .group:
                                    let groupId: SessionId = SessionId(.group, hex: threadId)
                                    return dependencies.mutate(cache: .libSession) { cache in
                                        cache.groupName(groupSessionId: groupId)
                                    }
                                    
                                case .community:
                                    return try? OpenGroup
                                        .select(.name)
                                        .filter(id: threadId)
                                        .asRequest(of: String.self)
                                        .fetchOne(db)
                                    
                                default: return nil
                            }
                        },
                        shouldShowForMessageRequest: { false }
                    )
                }
                
                return (threadId, threadVariant, interactionId, interaction.variant, interaction.wasRead, 0)
            }
            
            return nil
        }
        
        guard dependencies.mutate(cache: .libSession, { $0.get(.areCallsEnabled) }) && Permissions.microphone == .granted else {
            let state: CallMessage.MessageInfo.State = (dependencies.mutate(cache: .libSession) { cache in
                (cache.get(.areCallsEnabled) ? .permissionDeniedMicrophone : .permissionDenied)
            })
            
            Log.info(.calls, "Microphone permission is \(AVAudioSession.sharedInstance().recordPermission)")
            
            if let interaction: Interaction = try MessageReceiver.insertCallInfoMessage(db, threadId: threadId, threadVariant: threadVariant, for: message, state: state, using: dependencies), let interactionId: Int64 = interaction.id {
                let thread: SessionThread = try SessionThread.upsert(
                    db,
                    id: sender,
                    variant: .contact,
                    values: .existingOrDefault,
                    using: dependencies
                )
                
                if !suppressNotifications && !interaction.wasRead {
                    /// Update the `CallMessage.state` value so the correct notification logic can occur
                    message.state = state
                    
                    try? dependencies[singleton: .notificationsManager].notifyUser(
                        cat: .messageReceiver,
                        message: message,
                        threadId: thread.id,
                        threadVariant: thread.variant,
                        interactionIdentifier: (interaction.serverHash ?? "\(interactionId)"),
                        interactionVariant: interaction.variant,
                        attachmentDescriptionInfo: nil,
                        openGroupUrlInfo: nil,
                        applicationState: (isMainAppActive ? .active : .background),
                        extensionBaseUnreadCount: nil,
                        currentUserSessionIds: [dependencies[cache: .general].sessionId.hexString],
                        displayNameRetriever: { sessionId, _ in
                            Profile.displayNameNoFallback(
                                db,
                                id: sessionId,
                                threadVariant: thread.variant
                            )
                        },
                        groupNameRetriever: { threadId, threadVariant in
                            switch threadVariant {
                                case .group:
                                    let groupId: SessionId = SessionId(.group, hex: threadId)
                                    return dependencies.mutate(cache: .libSession) { cache in
                                        cache.groupName(groupSessionId: groupId)
                                    }
                                    
                                case .community:
                                    return try? OpenGroup
                                        .select(.name)
                                        .filter(id: threadId)
                                        .asRequest(of: String.self)
                                        .fetchOne(db)
                                    
                                default: return nil
                            }
                        },
                        shouldShowForMessageRequest: { false }
                    )
                }
                
                // Trigger the missed call UI if needed
                NotificationCenter.default.post(
                    name: .missedCall,
                    object: nil,
                    userInfo: [ Notification.Key.senderId.rawValue: sender ]
                )
                return (threadId, threadVariant, interactionId, interaction.variant, interaction.wasRead, 0)
            }
            
            return nil
        }
        
        /// If we are already on a call that is different from the current one then we are in a busy state
        guard
            dependencies[singleton: .callManager].currentCall == nil ||
            dependencies[singleton: .callManager].currentCall?.uuid == message.uuid
        else {
            return try handleIncomingCallOfferInBusyState(
                db,
                threadId: threadId,
                threadVariant: threadVariant,
                message: message,
                suppressNotifications: suppressNotifications,
                using: dependencies
            )
        }
        
        /// Insert the call info message for the message (this needs to happen whether it's a new call or an existing call since the PN
        /// extension will no longer insert this itself)
        let interaction: Interaction? = try MessageReceiver.insertCallInfoMessage(
            db,
            threadId: threadId,
            threadVariant: threadVariant,
            for: message,
            using: dependencies
        )
        
        /// Ignore pre offer message after the same call instance has been generated
        guard dependencies[singleton: .callManager].currentCall == nil else {
            Log.info(.calls, "Ignoring pre-offer message for call[\(message.uuid)] instance because it is already active.")
            return interaction.map { interaction in
                interaction.id.map { (threadId, threadVariant, $0, interaction.variant, interaction.wasRead, 0) }
            }
        }
        
        /// Handle UI for the new call
        dependencies[singleton: .callManager].showCallUIForCall(
            caller: sender,
            uuid: message.uuid,
            mode: .answer,
            interactionId: interaction?.id
        )
        return interaction.map { interaction in
            interaction.id.map { (threadId, threadVariant, $0, interaction.variant, interaction.wasRead, 0) }
        }
    }
    
    private static func handleOfferCallMessage(_ db: ObservingDatabase, message: CallMessage, using dependencies: Dependencies) {
        Log.info(.calls, "Received offer message.")
        
        // Ensure we have a call manager before continuing
        guard
            let currentCall: CurrentCallProtocol = dependencies[singleton: .callManager].currentCall,
            currentCall.uuid == message.uuid,
            let sdp: String = message.sdps.first
        else { return }
        
        let sdpDescription: RTCSessionDescription = RTCSessionDescription(type: .offer, sdp: sdp)
        currentCall.didReceiveRemoteSDP(sdp: sdpDescription)
    }
    
    private static func handleAnswerCallMessage(
        _ db: ObservingDatabase,
        message: CallMessage,
        using dependencies: Dependencies
    ) {
        Log.info(.calls, "Received answer message.")
        
        guard
            dependencies[singleton: .callManager].currentWebRTCSessionMatches(callId: message.uuid),
            var currentCall: CurrentCallProtocol = dependencies[singleton: .callManager].currentCall,
            currentCall.uuid == message.uuid,
            let sender: String = message.sender
        else { return }
        
        guard sender != dependencies[cache: .general].sessionId.hexString else {
            guard currentCall.mode == .answer && !currentCall.hasStartedConnecting else { return }
            
            Task { @MainActor [callManager = dependencies[singleton: .callManager]] in
                callManager.dismissAllCallUI()
            }
            dependencies[singleton: .callManager].reportCurrentCallEnded(reason: .answeredElsewhere)
            return
        }
        guard let sdp: String = message.sdps.first else { return }
        
        let sdpDescription: RTCSessionDescription = RTCSessionDescription(type: .answer, sdp: sdp)
        currentCall.hasStartedConnecting = true
        currentCall.didReceiveRemoteSDP(sdp: sdpDescription)
        
        Task { @MainActor [callManager = dependencies[singleton: .callManager]] in
            callManager.handleAnswerMessage(message)
        }
    }
    
    private static func handleEndCallMessage(
        _ db: ObservingDatabase,
        message: CallMessage,
        using dependencies: Dependencies
    ) {
        Log.info(.calls, "Received end call message.")
        
        guard
            dependencies[singleton: .callManager].currentWebRTCSessionMatches(callId: message.uuid),
            let currentCall: CurrentCallProtocol = dependencies[singleton: .callManager].currentCall,
            currentCall.uuid == message.uuid,
            !currentCall.hasEnded,
            let sender: String = message.sender
        else { return }
        
        Task { @MainActor [callManager = dependencies[singleton: .callManager]] in
            callManager.dismissAllCallUI()
        }
        
        dependencies[singleton: .callManager].reportCurrentCallEnded(
            reason: (sender == dependencies[cache: .general].sessionId.hexString ?
                .declinedElsewhere :
                .remoteEnded
            )
        )
    }
    
    // MARK: - Convenience
    
    public static func handleIncomingCallOfferInBusyState(
        _ db: ObservingDatabase,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: CallMessage,
        suppressNotifications: Bool,
        using dependencies: Dependencies
    ) throws -> InsertedInteractionInfo? {
        let messageInfo: CallMessage.MessageInfo = CallMessage.MessageInfo(state: .missed)
        
        guard
            let caller: String = message.sender,
            let messageInfoData: Data = try? JSONEncoder(using: dependencies).encode(messageInfo),
            dependencies.mutate(cache: .libSession, { cache in
                !cache.isMessageRequest(threadId: caller, threadVariant: threadVariant)
            })
        else { throw MessageReceiverError.invalidMessage }
        
        let messageSentTimestampMs: Int64 = (
            message.sentTimestampMs.map { Int64($0) } ??
            dependencies.networkOffsetTimestampMs()
        )
        let interaction: Interaction = try Interaction(
            serverHash: message.serverHash,
            messageUuid: message.uuid,
            threadId: threadId,
            threadVariant: threadVariant,
            authorId: caller,
            variant: .infoCall,
            body: String(data: messageInfoData, encoding: .utf8),
            timestampMs: messageSentTimestampMs,
            wasRead: dependencies.mutate(cache: .libSession) { cache in
                cache.timestampAlreadyRead(
                    threadId: threadId,
                    threadVariant: threadVariant,
                    timestampMs: messageSentTimestampMs,
                    openGroupUrlInfo: nil
                )
            },
            expiresInSeconds: message.expiresInSeconds,
            expiresStartedAtMs: message.expiresStartedAtMs,
            using: dependencies
        )
        .inserted(db)
        
        /// If we are suppressing notifications then we are loading in messages that were cached by the extensions, in which case it's
        /// an old message so we would have already sent the response (all we would have needed to do in this case was save the
        /// `interaction` above to the database)
        if !suppressNotifications {
            Log.info(.calls, "Sending end call message because there is an ongoing call.")
            
            try sendIncomingCallOfferInBusyStateResponse(
                threadId: threadId,
                message: message,
                disappearingMessagesConfiguration: try? DisappearingMessagesConfiguration
                    .fetchOne(db, id: threadId),
                authMethod: try Authentication.with(swarmPublicKey: threadId, using: dependencies),
                onEvent: MessageSender.standardEventHandling(using: dependencies),
                using: dependencies
            )
            .send(using: dependencies)
            .subscribe(on: DispatchQueue.global(qos: .userInitiated))
            .sinkUntilComplete()
        }
        
        return interaction.id.map { (threadId, threadVariant, $0, interaction.variant, interaction.wasRead, 0) }
    }
    
    public static func sendIncomingCallOfferInBusyStateResponse(
        threadId: String,
        message: CallMessage,
        disappearingMessagesConfiguration: DisappearingMessagesConfiguration?,
        authMethod: AuthenticationMethod,
        onEvent: ((MessageSender.Event) -> Void)?,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Message> {
        return try MessageSender.preparedSend(
            message: CallMessage(
                uuid: message.uuid,
                kind: .endCall,
                sdps: [],
                sentTimestampMs: nil // Explicitly nil as it's a separate message from above
            )
            .with(disappearingMessagesConfiguration?.forcedWithDisappearAfterReadIfNeeded()),
            to: .contact(publicKey: threadId),
            namespace: .default,
            interactionId: nil,      // Explicitly nil as it's a separate message from above
            attachments: nil,
            authMethod: authMethod,
            onEvent: onEvent,
            using: dependencies
        )
    }
    
    @discardableResult public static func insertCallInfoMessage(
        _ db: ObservingDatabase,
        threadId: String,
        threadVariant: SessionThread.Variant,
        for message: CallMessage,
        state: CallMessage.MessageInfo.State? = nil,
        using dependencies: Dependencies
    ) throws -> Interaction? {
        guard (
            try? Interaction
                .filter(Interaction.Columns.variant == Interaction.Variant.infoCall)
                .filter(Interaction.Columns.messageUuid == message.uuid)
                .isEmpty(db)
            ).defaulting(to: false)
        else { throw MessageReceiverError.duplicatedCall }
        
        guard
            let sender: String = message.sender,
            dependencies.mutate(cache: .libSession, { cache in
                !cache.isMessageRequest(threadId: sender, threadVariant: threadVariant)
            })
        else { return nil }
        
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let messageInfo: CallMessage.MessageInfo = CallMessage.MessageInfo(
            state: state.defaulting(
                to: (sender == userSessionId.hexString ?
                    .outgoing :
                    .incoming
                )
            )
        )
        let timestampMs: Int64 = (
            message.sentTimestampMs.map { Int64($0) } ??
            dependencies.networkOffsetTimestampMs()
        )
        
        guard let messageInfoData: Data = try? JSONEncoder(using: dependencies).encode(messageInfo) else {
            return nil
        }
        
        return try Interaction(
            serverHash: message.serverHash,
            messageUuid: message.uuid,
            threadId: threadId,
            threadVariant: threadVariant,
            authorId: sender,
            variant: .infoCall,
            body: String(data: messageInfoData, encoding: .utf8),
            timestampMs: timestampMs,
            wasRead: dependencies.mutate(cache: .libSession) { cache in
                cache.timestampAlreadyRead(
                    threadId: threadId,
                    threadVariant: threadVariant,
                    timestampMs: timestampMs,
                    openGroupUrlInfo: nil
                )
            },
            expiresInSeconds: message.expiresInSeconds,
            expiresStartedAtMs: message.expiresStartedAtMs,
            using: dependencies
        )
        .inserted(db)
    }
}
