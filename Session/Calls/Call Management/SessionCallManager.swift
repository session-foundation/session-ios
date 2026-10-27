// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import CallKit
import GRDB
import WebRTC
import SessionUIKit
import SessionMessagingKit
import SignalUtilitiesKit
import SessionUtilitiesKit

// MARK: - CXProviderConfiguration

public extension CXProviderConfiguration {
    static func defaultConfiguration(_ useSystemCallLog: Bool = false) -> CXProviderConfiguration {
        let iconMaskImage: UIImage = #imageLiteral(resourceName: "SessionGreen32")
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.iconTemplateImageData = iconMaskImage.pngData()
        configuration.includesCallsInRecents = useSystemCallLog
        
        return configuration
    }
}

// MARK: - SessionCallManager

public final class SessionCallManager: NSObject, CallManagerProtocol {
    private static let endCallMessageSendTimeout: DispatchTimeInterval = .seconds(10)
    
    let dependencies: Dependencies
    
    let provider: CXProvider?
    let callController: CXCallController?
    private var pendingOfferSDP: (uuid: String, sdp: String)? = nil
    private var pendingICECandidates: [(message: CallMessage, sdpMLineIndexes: [UInt32], sdpMids: [String])] = []
    @ThreadSafeObject private var pendingEndCallMessageSend: Task<Void, Never>? = nil
    
    public var currentCall: CurrentCallProtocol? = nil {
        willSet {
            if (newValue != nil) {
                DispatchQueue.main.async {
                    UIApplication.shared.isIdleTimerDisabled = true
                }
            } else {
                DispatchQueue.main.async {
                    UIApplication.shared.isIdleTimerDisabled = false
                }
            }
        }
    }
    
    // MARK: - Initialization
    
    init(useSystemCallLog: Bool = false, using dependencies: Dependencies) {
        self.dependencies = dependencies
        
        if Preferences.isCallKitSupported {
            self.provider = CXProvider(configuration: .defaultConfiguration(useSystemCallLog))
            self.callController = CXCallController()
        }
        else {
            self.provider = nil
            self.callController = nil
        }
        
        super.init()
        
        // We cannot assert singleton here, because this class gets rebuilt when the user changes relevant call settings
        self.provider?.setDelegate(self, queue: nil)
    }
    
    // MARK: - Report calls
    
    public func reportFakeCall(info: String) {
        let callId = UUID()
        self.provider?.reportNewIncomingCall(
            with: callId,
            update: CXCallUpdate()
        ) { _ in
            Log.error(.calls, "Reported fake incoming call to CallKit due to: \(info)")
        }
        self.provider?.reportCall(
            with: callId,
            endedAt: nil,
            reason: .failed
        )
    }
    
    public func setCurrentCall(_ call: CurrentCallProtocol?) {
        self.currentCall = call
        
        if call != nil {
            drainPendingSignalingIfNeeded()
        }
    }
    
    public func reportOutgoingCall(_ call: SessionCall) {
        Log.assertOnMainThread()
        storeOngoingCall(call)
        
        call.stateDidChange = {
            if call.hasStartedConnecting {
                self.provider?.reportOutgoingCall(with: call.callId, startedConnectingAt: call.connectingDate)
            }
            
            if call.hasConnected {
                self.provider?.reportOutgoingCall(with: call.callId, connectedAt: call.connectedDate)
            }
        }
    }
    
    public func reportIncomingCall(_ call: CurrentCallProtocol, callerName: String, completion: @escaping (Error?) -> Void) {
        // If CallKit isn't supported then we don't have anything to report the call to
        guard Preferences.isCallKitSupported else {
            storeOngoingCall(call)
            completion(nil)
            return
        }
        
        // Show contact name + session id (truncated...) opening outgoing call in apple watch
        let callDisplay = generateDisplayForCall(call)
        
        // Construct a CXCallUpdate describing the incoming call, including the caller.
        let update = CXCallUpdate()
        update.localizedCallerName = callerName
        update.remoteHandle = CXHandle(type: .generic, value: callDisplay)
        update.hasVideo = false

        disableUnsupportedFeatures(callUpdate: update)

        // Report the incoming call to the system
        self.provider?.reportNewIncomingCall(with: call.callId, update: update) { error in
            guard error == nil else {
                self.reportCurrentCallEnded(reason: .failed)
                completion(error)
                return
            }
            self.storeOngoingCall(call)
            completion(nil)
        }
    }
    
    public func reportCurrentCallEnded(reason: CXCallEndedReason) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.reportCurrentCallEnded(reason: reason)
            }
            return
        }
        
        guard let call = currentCall else {
            self.cleanUpPreviousCall()
            self.suspendDatabaseIfCallEndedInBackground()
            return
        }
        
        self.provider?.reportCall(with: call.callId, endedAt: nil, reason: reason)
        
        switch (reason) {
            case .answeredElsewhere: call.updateCallMessage(mode: .answeredElsewhere, using: dependencies)
            case .unanswered: call.updateCallMessage(mode: .unanswered, using: dependencies)
            case .declinedElsewhere: call.updateCallMessage(mode: .local, using: dependencies)
            default: call.updateCallMessage(mode: .remote, using: dependencies)
        }
        
        _pendingEndCallMessageSend.set(to: call.endCallMessageSend)
        self.cleanUpPreviousCall()
        self.suspendDatabaseIfCallEndedInBackground()
    }
    
    public func currentWebRTCSessionMatches(callId: String) -> Bool {
        return (
            WebRTCSession.current != nil &&
            WebRTCSession.current?.uuid == callId
        )
    }
    
    // MARK: - Util
    
    /// The notification extension reads these to decide whether an incoming call message belongs to a call the main app is
    /// already handling
    private func storeOngoingCall(_ call: CurrentCallProtocol) {
        dependencies[defaults: .appGroup, key: .isCallOngoing] = true
        dependencies[defaults: .appGroup, key: .ongoingCallUuid] = call.uuid
        dependencies[defaults: .appGroup, key: .lastCallPreOffer] = Date()
    }
    
    private func drainPendingSignalingIfNeeded() {
        guard
            let currentCall = currentCall,
            !currentCall.hasEnded,
            let webRTCSession = WebRTCSession.current,
            webRTCSession.uuid == currentCall.uuid
        else { return }

        if let pending = pendingOfferSDP, pending.uuid == currentCall.uuid {
            currentCall.didReceiveRemoteSDP(sdp: RTCSessionDescription(type: .offer, sdp: pending.sdp))
            pendingOfferSDP = nil
        }

        let candidates = pendingICECandidates
        pendingICECandidates = []
        candidates.forEach { handleICECandidates(message: $0.message, sdpMLineIndexes: $0.sdpMLineIndexes, sdpMids: $0.sdpMids) }
    }
    
    private func disableUnsupportedFeatures(callUpdate: CXCallUpdate) {
        // Call Holding is failing to restart audio when "swapping" calls on the CallKit screen
        // until user returns to in-app call screen.
        callUpdate.supportsHolding = false

        // Not yet supported
        callUpdate.supportsGrouping = false
        callUpdate.supportsUngrouping = false

        // Is there any reason to support this?
        callUpdate.supportsDTMF = false
    }
    
    public func suspendDatabaseIfCallEndedInBackground() {
        Log.info(.calls, "Called suspendDatabaseIfCallEndedInBackground.")
        
        if dependencies[singleton: .appContext].isInBackground {
            /// Stop all jobs except for message sending and when completed suspend the database
            Task.detached(priority: .userInitiated) { [weak self, dependencies, pendingEndCallMessageSend] in
                /// Waiting for the `endCall` message keeps the app running in the background with the database open, so hold a
                /// background task to stop iOS suspending it before the database is (which would crash with `0xdead10cc`)
                try? await SessionBackgroundTask.run(label: "Suspend after call", using: dependencies) {
                    await dependencies[singleton: .jobRunner].stopAndClearJobs(
                        filters: JobRunner.Filters(
                            exclude: [.variant(.messageSend)]
                        )
                    )
                    
                    /// The `endCall` message is the only way the other party learns the call ended - it isn't a job (so the exclusion
                    /// above doesn't protect it) and it needs both the database and the network, so if it hasn't gone out by the time
                    /// we suspend them the other party is left "connecting" until they give up
                    if let pendingEndCallMessageSend {
                        await SessionCallManager.waitForEndCallMessageSend(pendingEndCallMessageSend, using: dependencies)
                    }
                    
                    if self?.currentCall?.hasEnded != false {
                        await dependencies[singleton: .network].suspendNetworkAccess()
                        await dependencies[singleton: .storage].suspendDatabaseAccess()
                        Log.flush()
                    }
                }
            }
        }
    }
    
    private static func waitForEndCallMessageSend(_ send: Task<Void, Never>, using dependencies: Dependencies) async {
        let (outcome, continuation) = AsyncStream<Bool>.makeStream()
        let sendWatcher: Task<Void, Never> = Task {
            await send.value
            continuation.yield(true)
        }
        let timeout: Task<Void, Never> = Task {
            try? await dependencies.sleep(for: endCallMessageSendTimeout)
            continuation.yield(false)
        }
        
        let didSend: Bool = (await outcome.first(where: { _ in true }) ?? false)
        continuation.finish()
        sendWatcher.cancel()
        timeout.cancel()
        
        if !didSend {
            Log.warn(.calls, "Suspending before the end call message was sent.")
        }
    }
    
    public func handlePendingOfferSDP(uuid: String, sdp: String) {
        self.pendingOfferSDP = (uuid, sdp)
        self.drainPendingSignalingIfNeeded()
    }
    
    public func clearPendingSignaling(for uuid: String) {
        if pendingOfferSDP?.uuid == uuid { pendingOfferSDP = nil }
        pendingICECandidates.removeAll { $0.message.uuid == uuid }
    }
    
    // MARK: - UI
    
    public func showCallUIForCall(caller: String, uuid: String, mode: CallMode, interactionId: Int64?) {
        Task(priority: .userInitiated) { [dependencies] in
            let call: SessionCall = try await dependencies[singleton: .storage].read { [dependencies] db in
                SessionCall(
                    for: caller,
                    contactName: Profile.displayName(db, id: caller),
                    uuid: uuid,
                    mode: mode,
                    using: dependencies
                )
            }
            
            call.reportIncomingCallIfNeeded { [dependencies] error in
                if let error = error {
                    Log.error(.calls, "Failed to report incoming call to CallKit due to error: \(error)")
                    return
                }
                
                DispatchQueue.main.async {
                    guard
                        dependencies[singleton: .appContext].isMainAppAndForeground,
                        let currentFrontMostViewController: UIViewController = dependencies[singleton: .appContext].frontMostViewController
                    else { return }
                    
                    if
                        let conversationVC: ConversationVC = currentFrontMostViewController as? ConversationVC,
                        conversationVC.viewModel.state.threadId == call.sessionId
                    {
                        let callVC = CallVC(for: call, using: dependencies)
                        currentFrontMostViewController.present(callVC, animated: true, completion: nil)
                    }
                    else if !Preferences.isCallKitSupported {
                        let incomingCallBanner = IncomingCallBanner(for: call, using: dependencies)
                        incomingCallBanner.show()
                    }
                }
            }
        }
    }
    
    public func handleICECandidates(message: CallMessage, sdpMLineIndexes: [UInt32], sdpMids: [String]) {
        guard
            let currentWebRTCSession = WebRTCSession.current,
            currentWebRTCSession.uuid == message.uuid
        else {
            pendingICECandidates.append((message: message, sdpMLineIndexes: sdpMLineIndexes, sdpMids: sdpMids))
            return
        }
        
        var candidates: [RTCIceCandidate] = []
        let sdps = message.sdps
        for i in 0..<sdps.count {
            let sdp = sdps[i]
            let sdpMLineIndex = sdpMLineIndexes[i]
            let sdpMid = sdpMids[i]
            let candidate = RTCIceCandidate(sdp: sdp, sdpMLineIndex: Int32(sdpMLineIndex), sdpMid: sdpMid)
            candidates.append(candidate)
        }
        currentWebRTCSession.handleICECandidates(candidates)
    }
    
    @MainActor public func handleAnswerMessage(_ message: CallMessage) {
        guard dependencies[singleton: .appContext].isValid else { return }
        
        (dependencies[singleton: .appContext].frontMostViewController as? CallVC)?.handleAnswerMessage(message)
    }
    
    @MainActor public func dismissAllCallUI() {
        guard dependencies[singleton: .appContext].isValid else { return }
        
        IncomingCallBanner.current?.dismiss()
        (dependencies[singleton: .appContext].frontMostViewController as? CallVC)?.handleEndCallMessage()
        MiniCallView.current?.dismiss()
    }
    
    public func cleanUpPreviousCall() {
        Log.info(.calls, "Clean up calls")
        
        pendingOfferSDP = nil
        pendingICECandidates = []
        WebRTCSession.current?.dropConnection()
        WebRTCSession.current = nil
        currentCall = nil
        dependencies[defaults: .appGroup, key: .isCallOngoing] = false
        dependencies[defaults: .appGroup, key: .ongoingCallUuid] = nil
        dependencies[defaults: .appGroup, key: .lastCallPreOffer] = nil
        
        if dependencies[singleton: .appContext].isNotInForeground {
            dependencies[singleton: .appReadiness].runNowOrWhenAppDidBecomeReady { [poller = dependencies[singleton: .currentUserPoller]] in
                Task(priority: .userInitiated) {
                    await poller.stop()
                }
            }
            Log.flush()
        }
    }
    
    func generateDisplayForCall(_ call: CurrentCallProtocol) -> String {
        guard
            let sessionCall = call as? SessionCall,
            sessionCall.contactName.isEmpty == false
        else {
            /// When contact name is empty display
            /// ex. 1234...7890
            return call.sessionId.truncated(prefix: 4, suffix: 4)
        }

        /// Display contact name + truncated session id prefix 4
        /// ex. John 1234...
        let truncatedSessionId = sessionCall.sessionId.truncated(prefix: 4, suffix: 0)
        return "\(sessionCall.contactName) \(truncatedSessionId)"
    }
}
