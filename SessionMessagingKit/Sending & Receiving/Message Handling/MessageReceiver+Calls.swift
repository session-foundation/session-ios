// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import AVFAudio
import GRDB
import WebRTC
import SessionUtilitiesKit
import SessionSnodeKit

extension MessageReceiver {
    public static func handleCallMessage(
        _ db: Database,
        threadId: String,
        threadVariant: SessionThread.Variant,
        message: CallMessage,
        using dependencies: Dependencies
    ) throws {
        // Only support calls from contact threads
        guard threadVariant == .contact else { return }
        
        switch message.kind {
            case .preOffer: try MessageReceiver.handleNewCallMessage(db, message: message, using: dependencies)
            case .offer: MessageReceiver.handleOfferCallMessage(db, message: message)
            case .answer: MessageReceiver.handleAnswerCallMessage(db, message: message)
            case .provisionalAnswer: break // TODO: Implement
                
            case let .iceCandidates(sdpMLineIndexes, sdpMids):
                Singleton.callManager.handleICECandidates(
                    message: message,
                    sdpMLineIndexes: sdpMLineIndexes,
                    sdpMids: sdpMids
                )
                
            case .endCall: MessageReceiver.handleEndCallMessage(db, message: message)
        }
    }
    
    // MARK: - Specific Handling
    
    private static func handleNewCallMessage(_ db: Database, message: CallMessage, using dependencies: Dependencies) throws {
        SNLog("[Calls] Received pre-offer message.")
        
        // Determine whether the app is active based on the prefs rather than the UIApplication state to avoid
        // requiring main-thread execution
        let isMainAppActive: Bool = (UserDefaults.sharedLokiProject?[.isMainAppActive]).defaulting(to: false)
        
        // It is enough just ignoring the pre offers, other call messages
        // for this call would be dropped because of no Session call instance
        guard
            Singleton.hasAppContext,
            Singleton.appContext.isMainApp,
            let sender: String = message.sender,
            (try? Contact
                .filter(id: sender)
                .select(.isApproved)
                .asRequest(of: Bool.self)
                .fetchOne(db))
                .defaulting(to: false)
        else { return }
        guard let timestamp = message.sentTimestamp, TimestampUtils.isWithinOneMinute(timestampMs: timestamp) else {
            // Add missed call message for call offer messages from more than one minute
            if let interaction: Interaction = try MessageReceiver.insertCallInfoMessage(db, for: message, state: .missed, using: dependencies) {
                let thread: SessionThread = try SessionThread.upsert(
                    db,
                    id: sender,
                    variant: .contact,
                    values: .existingOrDefault,
                    using: dependencies
                )
                
                if !interaction.wasRead {
                    SessionEnvironment.shared?.notificationsManager?
                        .notifyUser(
                            db,
                            forIncomingCall: interaction,
                            in: thread,
                            applicationState: (isMainAppActive ? .active : .background)
                        )
                }
            }
            return
        }
        
        guard db[.areCallsEnabled] && Permissions.microphone == .granted else {
            let state: CallMessage.MessageInfo.State = (db[.areCallsEnabled] ? .permissionDeniedMicrophone : .permissionDenied)
            
            SNLog("[MessageReceiver+Calls] Microphone permission is \(AVAudioSession.sharedInstance().recordPermission)")
            
            if let interaction: Interaction = try MessageReceiver.insertCallInfoMessage(db, for: message, state: state, using: dependencies) {
                let thread: SessionThread = try SessionThread.upsert(
                    db,
                    id: sender,
                    variant: .contact,
                    values: .existingOrDefault,
                    using: dependencies
                )
                
                if !interaction.wasRead {
                    SessionEnvironment.shared?.notificationsManager?
                        .notifyUser(
                            db,
                            forIncomingCall: interaction,
                            in: thread,
                            applicationState: (isMainAppActive ? .active : .background)
                        )
                }
                
                // Trigger the missed call UI if needed
                NotificationCenter.default.post(
                    name: .missedCall,
                    object: nil,
                    userInfo: [ Notification.Key.senderId.rawValue: sender ]
                )
            }
            return
        }
        
        // Ignore pre offer message after the same call instance has been generated
        if let currentCall: CurrentCallProtocol = Singleton.callManager.currentCall, currentCall.uuid == message.uuid {
            SNLog("[MessageReceiver+Calls] Ignoring pre-offer message for call[\(currentCall.uuid)] instance because it is already active.")
            return
        }
        
        guard Singleton.callManager.currentCall == nil else {
            try MessageReceiver.handleIncomingCallOfferInBusyState(db, message: message)
            return
        }
        
        let interaction: Interaction? = try MessageReceiver.insertCallInfoMessage(db, for: message, using: dependencies)
        
        // Handle UI
        Singleton.callManager.showCallUIForCall(
            caller: sender,
            uuid: message.uuid,
            mode: .answer,
            interactionId: interaction?.id
        )
    }
    
    private static func handleOfferCallMessage(_ db: Database, message: CallMessage) {
        SNLog("[Calls] Received offer message.")
        
        // Ensure we have a call manager before continuing
        guard
            let currentCall: CurrentCallProtocol = Singleton.callManager.currentCall,
            currentCall.uuid == message.uuid,
            let sdp: String = message.sdps.first
        else { return }
        
        let sdpDescription: RTCSessionDescription = RTCSessionDescription(type: .offer, sdp: sdp)
        currentCall.didReceiveRemoteSDP(sdp: sdpDescription)
    }
    
    private static func handleAnswerCallMessage(_ db: Database, message: CallMessage) {
        SNLog("[Calls] Received answer message.")
        
        guard
            Singleton.callManager.currentWebRTCSessionMatches(callId: message.uuid),
            var currentCall: CurrentCallProtocol = Singleton.callManager.currentCall,
            currentCall.uuid == message.uuid,
            let sender: String = message.sender
        else { return }
        
        guard sender != getUserHexEncodedPublicKey(db) else {
            guard !currentCall.hasStartedConnecting else { return }
            
            Singleton.callManager.dismissAllCallUI()
            Singleton.callManager.reportCurrentCallEnded(reason: .answeredElsewhere)
            return
        }
        guard let sdp: String = message.sdps.first else { return }
        
        let sdpDescription: RTCSessionDescription = RTCSessionDescription(type: .answer, sdp: sdp)
        currentCall.hasStartedConnecting = true
        currentCall.didReceiveRemoteSDP(sdp: sdpDescription)
        Singleton.callManager.handleAnswerMessage(message)
    }
    
    private static func handleEndCallMessage(_ db: Database, message: CallMessage) {
        SNLog("[Calls] Received end call message.")
        
        guard
            Singleton.callManager.currentWebRTCSessionMatches(callId: message.uuid),
            let currentCall: CurrentCallProtocol = Singleton.callManager.currentCall,
            currentCall.uuid == message.uuid,
            let sender: String = message.sender
        else { return }
        
        Singleton.callManager.dismissAllCallUI()
        Singleton.callManager.reportCurrentCallEnded(
            reason: (sender == getUserHexEncodedPublicKey(db) ?
                .declinedElsewhere :
                .remoteEnded
            )
        )
    }
    
    // MARK: - Convenience
    
    public static func handleIncomingCallOfferInBusyState(
        _ db: Database,
        message: CallMessage,
        using dependencies: Dependencies = Dependencies()
    ) throws {
        let messageInfo: CallMessage.MessageInfo = CallMessage.MessageInfo(state: .missed)
        
        guard
            let caller: String = message.sender,
            let messageInfoData: Data = try? JSONEncoder().encode(messageInfo),
            let thread: SessionThread = try SessionThread.fetchOne(db, id: caller),
            !thread.isMessageRequest(db)
        else { return }
        
        SNLog("[Calls] Sending end call message because there is an ongoing call.")
        
        let messageSentTimestamp: Int64 = (
            message.sentTimestamp.map { Int64($0) } ??
            SnodeAPI.currentOffsetTimestampMs()
        )
        _ = try Interaction(
            serverHash: message.serverHash,
            messageUuid: message.uuid,
            threadId: thread.id,
            threadVariant: thread.variant,
            authorId: caller,
            variant: .infoCall,
            body: String(data: messageInfoData, encoding: .utf8),
            timestampMs: messageSentTimestamp,
            wasRead: LibSession.timestampAlreadyRead(
                threadId: thread.id,
                threadVariant: thread.variant,
                timestampMs: (messageSentTimestamp * 1000),
                userPublicKey: getUserHexEncodedPublicKey(db),
                openGroup: nil,
                using: dependencies
            ),
            expiresInSeconds: message.expiresInSeconds,
            expiresStartedAtMs: message.expiresStartedAtMs
        )
        .inserted(db)
        
        MessageSender.sendImmediate(
            data: try MessageSender
                .preparedSendData(
                    db,
                    message: CallMessage(
                        uuid: message.uuid,
                        kind: .endCall,
                        sdps: [],
                        sentTimestampMs: nil // Explicitly nil as it's a separate message from above
                    )
                    .with(try? thread.disappearingMessagesConfiguration
                        .fetchOne(db)?
                        .forcedWithDisappearAfterReadIfNeeded()
                    ),
                    to: try Message.Destination.from(db, threadId: thread.id, threadVariant: thread.variant),
                    namespace: try Message.Destination
                        .from(db, threadId: thread.id, threadVariant: thread.variant)
                        .defaultNamespace,
                    interactionId: nil,      // Explicitly nil as it's a separate message from above
                    using: dependencies
                ),
            using: dependencies
        )
        .subscribe(on: DispatchQueue.global(qos: .userInitiated))
        .sinkUntilComplete()
    }
    
    @discardableResult public static func insertCallInfoMessage(
        _ db: Database,
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
            let thread: SessionThread = try SessionThread.fetchOne(db, id: sender),
            !thread.isMessageRequest(db)
        else { return nil }
        
        let currentUserPublicKey: String = getUserHexEncodedPublicKey(db)
        let messageInfo: CallMessage.MessageInfo = CallMessage.MessageInfo(
            state: state.defaulting(
                to: (sender == currentUserPublicKey ?
                    .outgoing :
                    .incoming
                )
            )
        )
        let timestampMs: Int64 = (
            message.sentTimestamp.map { Int64($0) } ??
            SnodeAPI.currentOffsetTimestampMs()
        )
        
        guard let messageInfoData: Data = try? JSONEncoder().encode(messageInfo) else { return nil }
        
        return try Interaction(
            serverHash: message.serverHash,
            messageUuid: message.uuid,
            threadId: thread.id,
            threadVariant: thread.variant,
            authorId: sender,
            variant: .infoCall,
            body: String(data: messageInfoData, encoding: .utf8),
            timestampMs: timestampMs,
            wasRead: LibSession.timestampAlreadyRead(
                threadId: thread.id,
                threadVariant: thread.variant,
                timestampMs: (timestampMs * 1000),
                userPublicKey: currentUserPublicKey,
                openGroup: nil,
                using: dependencies
            ),
            expiresInSeconds: message.expiresInSeconds,
            expiresStartedAtMs: message.expiresStartedAtMs
        )
        .inserted(db)
    }
}
