// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import YYImage
import Combine
import CallKit
import GRDB
import WebRTC
import SessionUIKit
import SignalUtilitiesKit
import SessionMessagingKit
import SessionUtilitiesKit
import SessionSnodeKit

public final class SessionCall: CurrentCallProtocol, WebRTCSessionDelegate {
    private let dependencies: Dependencies
    
    // MARK: - Metadata Properties
    public let uuid: String
    public let callId: UUID // This is for CallKit
    public let sessionId: String
    let mode: CallMode
    var audioMode: AudioMode
    public let webRTCSession: WebRTCSession
    let isOutgoing: Bool
    var remoteSDP: RTCSessionDescription? = nil
    var callInteractionId: Int64?
    var answerCallAction: CXAnswerCallAction? = nil
    
    let contactName: String
    let profilePicture: UIImage
    let animatedProfilePicture: YYImage?
    
    var currentConnectionStep: ConnectionStep
    var connectionStepsRecord: [Bool]
    
    // MARK: - Control
    
    lazy public var videoCapturer: RTCVideoCapturer = {
        return RTCCameraVideoCapturer(delegate: webRTCSession.localVideoSource)
    }()
    
    var isRemoteVideoEnabled = false {
        didSet {
            remoteVideoStateDidChange?(isRemoteVideoEnabled)
        }
    }
    
    var isMuted = false {
        willSet {
            if newValue {
                webRTCSession.mute()
            } else {
                webRTCSession.unmute()
            }
        }
    }
    var isVideoEnabled = false {
        willSet {
            if newValue {
                webRTCSession.turnOnVideo()
            } else {
                webRTCSession.turnOffVideo()
            }
        }
    }
    
    // MARK: - Audio I/O mode
    
    enum AudioMode {
        case earpiece
        case speaker
        case headphone
        case bluetooth
    }
    
    // MARK: - Call State Properties
    
    var connectingDate: Date? {
        didSet {
            stateDidChange?()
            resetTimeoutTimerIfNeeded()
            hasStartedConnectingDidChange?()
        }
    }

    var connectedDate: Date? {
        didSet {
            stateDidChange?()
            hasConnectedDidChange?()
            updateCurrentConnectionStepIfPossible(
                mode == .offer ? OfferStep.connected : AnswerStep.connected
            )
        }
    }

    var endDate: Date? {
        didSet {
            stateDidChange?()
            hasEndedDidChange?()
            updateCallDetailedStatus?("")
        }
    }

    // Not yet implemented
    var isOnHold = false {
        didSet {
            stateDidChange?()
        }
    }

    // MARK: - State Change Callbacks
    
    var stateDidChange: (() -> Void)?
    var hasStartedConnectingDidChange: (() -> Void)?
    var hasConnectedDidChange: (() -> Void)?
    var hasEndedDidChange: (() -> Void)?
    var remoteVideoStateDidChange: ((Bool) -> Void)?
    var hasStartedReconnecting: (() -> Void)?
    var hasReconnected: (() -> Void)?
    var updateCallDetailedStatus: ((String) -> Void)?
    
    // MARK: - Derived Properties
    
    public var hasStartedConnecting: Bool {
        get { return connectingDate != nil }
        set { connectingDate = newValue ? Date() : nil }
    }

    public var hasConnected: Bool {
        get { return connectedDate != nil }
        set { connectedDate = newValue ? Date() : nil }
    }

    public var hasEnded: Bool {
        get { return endDate != nil }
        set { endDate = newValue ? Date() : nil }
    }
    
    var timeOutTimer: Timer? = nil
    var didTimeout = false

    var duration: TimeInterval {
        guard let connectedDate = connectedDate else {
            return 0
        }
        if let endDate = endDate {
            return endDate.timeIntervalSince(connectedDate)
        }

        return Date().timeIntervalSince(connectedDate)
    }
    
    var reconnectTimer: Timer? = nil
    
    // MARK: - Initialization
    
    init(_ db: Database, for sessionId: String, uuid: String, mode: CallMode, outgoing: Bool = false, using dependencies: Dependencies) {
        self.dependencies = dependencies
        self.sessionId = sessionId
        self.uuid = uuid
        self.callId = UUID()
        self.mode = mode
        self.audioMode = .earpiece
        self.webRTCSession = WebRTCSession.current ?? WebRTCSession(for: sessionId, with: uuid, using: dependencies)
        self.isOutgoing = outgoing
        self.currentConnectionStep = (mode == .offer ? OfferStep.initializing : AnswerStep.receivedOffer)
        self.connectionStepsRecord = [Bool](repeating: false, count: (mode == .answer ? 5 : 6))
        
        let avatarData: Data? = dependencies[singleton: .displayPictureManager].displayPicture(db, id: .user(sessionId))
        self.contactName = Profile.displayName(db, id: sessionId, threadVariant: .contact, using: dependencies)
        self.profilePicture = avatarData
            .map { UIImage(data: $0) }
            .defaulting(to: PlaceholderIcon.generate(seed: sessionId, text: self.contactName, size: 300))
        self.animatedProfilePicture = avatarData
            .map { data -> YYImage? in
                switch data.guessedImageFormat {
                    case .gif, .webp: return YYImage(data: data)
                    default: return nil
                }
            }
        
        WebRTCSession.current = self.webRTCSession
        self.webRTCSession.delegate = self
        
        if dependencies[singleton: .callManager].currentCall == nil {
            dependencies[singleton: .callManager].setCurrentCall(self)
        }
        else {
            Log.info(.calls, "A call is ongoing.")
        }
    }
    
    // stringlint:ignore_contents
    func reportIncomingCallIfNeeded(completion: @escaping (Error?) -> Void) {
        guard case .answer = mode else {
            dependencies[singleton: .callManager].reportFakeCall(info: "Call not in answer mode")
            return
        }
        
        setupTimeoutTimer()
        dependencies[singleton: .callManager].reportIncomingCall(self, callerName: contactName) { error in
            completion(error)
        }
    }
    
    public func didReceiveRemoteSDP(sdp: RTCSessionDescription) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async {
                self.didReceiveRemoteSDP(sdp: sdp)
            }
            return
        }
        
        Log.info(.calls, "Did receive remote sdp.")
        remoteSDP = sdp
        if hasStartedConnecting {
            webRTCSession.handleRemoteSDP(sdp, from: sessionId) // This sends an answer message internally
        }
        if mode == .answer {
            self.updateCurrentConnectionStepIfPossible(AnswerStep.receivedOffer)
        }
    }
    
    // MARK: - Actions
    
    public func startSessionCall(_ db: Database) {
        let sessionId: String = self.sessionId
        let messageInfo: CallMessage.MessageInfo = CallMessage.MessageInfo(state: .outgoing)
        
        guard
            case .offer = mode,
            let messageInfoData: Data = try? JSONEncoder().encode(messageInfo),
            let thread: SessionThread = try? SessionThread.fetchOne(db, id: sessionId)
        else { return }
        
        let webRTCSession: WebRTCSession = self.webRTCSession
        let timestampMs: Int64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        let disappearingMessagesConfiguration = try? thread.disappearingMessagesConfiguration.fetchOne(db)?.forcedWithDisappearAfterReadIfNeeded()
        let message: CallMessage = CallMessage(
            uuid: self.uuid,
            kind: .preOffer,
            sdps: [],
            sentTimestampMs: UInt64(timestampMs)
        )
        .with(disappearingMessagesConfiguration)
        
        let interaction: Interaction? = try? Interaction(
            messageUuid: self.uuid,
            threadId: sessionId,
            threadVariant: thread.variant,
            authorId: dependencies[cache: .general].sessionId.hexString,
            variant: .infoCall,
            body: String(data: messageInfoData, encoding: .utf8),
            timestampMs: timestampMs,
            expiresInSeconds: message.expiresInSeconds,
            expiresStartedAtMs: message.expiresStartedAtMs,
            using: dependencies
        )
        .inserted(db)
        
        self.callInteractionId = interaction?.id
        
        self.updateCurrentConnectionStepIfPossible(OfferStep.initializing)
        
        try? webRTCSession
            .sendPreOffer(
                db,
                message: message,
                interactionId: interaction?.id,
                in: thread
            )
            .retry(5)
            // Start the timeout timer for the call
            .handleEvents(receiveOutput: { [weak self] _ in self?.setupTimeoutTimer() })
            .flatMap { [weak self] _ in
                self?.updateCurrentConnectionStepIfPossible(OfferStep.sendingOffer)
                return webRTCSession
                    .sendOffer(to: thread)
                    .retry(5)
            }
            .sinkUntilComplete(
                receiveCompletion: { [weak self] result in
                    switch result {
                        case .finished:
                            SNLog("[Calls] Offer message sent")
                        case .failure(let error):
                            SNLog("[Calls] Error initializing call after 5 retries: \(error), ending call...")
                            self?.handleCallInitializationFailed()
                    }
                }
            )
    }
    
    func answerSessionCall() {
        guard case .answer = mode else { return }
        
        hasStartedConnecting = true
        
        if let sdp = remoteSDP {
            SNLog("[Calls] Got remote sdp already")
            self.updateCurrentConnectionStepIfPossible(AnswerStep.sendingAnswer)
            webRTCSession.handleRemoteSDP(sdp, from: sessionId) // This sends an answer message internally
        }
    }
    
    func answerSessionCallInBackground() {
        SNLog("[Calls] Answering call in background")
        self.answerSessionCall()
    }
    
    func endSessionCall() {
        guard !hasEnded else { return }
        
        let sessionId: String = self.sessionId
        
        webRTCSession.hangUp()
        webRTCSession.endCall(with: sessionId)
        hasEnded = true
    }
    
    func handleCallInitializationFailed() {
        self.endSessionCall()
        dependencies[singleton: .callManager].reportCurrentCallEnded(reason: .failed)
    }
    
    // MARK: - Call Message Handling
    
    public func updateCallMessage(mode: EndCallMode, using dependencies: Dependencies) {
        guard let callInteractionId: Int64 = callInteractionId else { return }
        
        let duration: TimeInterval = self.duration
        let hasStartedConnecting: Bool = self.hasStartedConnecting
        
        dependencies[singleton: .storage].writeAsync(
            updates: { db in
                guard let interaction: Interaction = try? Interaction.fetchOne(db, id: callInteractionId) else {
                    return
                }
                
                let updateToMissedIfNeeded: () throws -> () = {
                    let missedCallInfo: CallMessage.MessageInfo = CallMessage.MessageInfo(state: .missed)
                    
                    guard
                        let infoMessageData: Data = (interaction.body ?? "").data(using: .utf8),
                        let messageInfo: CallMessage.MessageInfo = try? JSONDecoder(using: dependencies).decode(
                            CallMessage.MessageInfo.self,
                            from: infoMessageData
                        ),
                        messageInfo.state == .incoming,
                        let missedCallInfoData: Data = try? JSONEncoder(using: dependencies)
                            .encode(missedCallInfo)
                    else { return }
                    
                    try interaction
                        .with(body: String(data: missedCallInfoData, encoding: .utf8))
                        .upserted(db)
                }
                let shouldMarkAsRead: Bool = try {
                    if duration > 0 { return true }
                    if hasStartedConnecting { return true }
                    
                    switch mode {
                        case .local:
                            try updateToMissedIfNeeded()
                            return true
                            
                        case .remote, .unanswered:
                            try updateToMissedIfNeeded()
                            return false
                            
                        case .answeredElsewhere: return true
                    }
                }()
                
                guard
                    shouldMarkAsRead,
                    let threadVariant: SessionThread.Variant = try? SessionThread
                        .filter(id: interaction.threadId)
                        .select(.variant)
                        .asRequest(of: SessionThread.Variant.self)
                        .fetchOne(db)
                else { return }
                
                try Interaction.markAsRead(
                    db,
                    interactionId: interaction.id,
                    threadId: interaction.threadId,
                    threadVariant: threadVariant,
                    includingOlder: false,
                    trySendReadReceipt: false,
                    using: dependencies
                )
            },
            completion: { [dependencies] _ in
                dependencies[singleton: .callManager].suspendDatabaseIfCallEndedInBackground()
            }
        )
    }
    
    // MARK: - Renderer
    
    func attachRemoteVideoRenderer(_ renderer: RTCVideoRenderer) {
        webRTCSession.attachRemoteRenderer(renderer)
    }
    
    func removeRemoteVideoRenderer(_ renderer: RTCVideoRenderer) {
        webRTCSession.removeRemoteRenderer(renderer)
    }
    
    func attachLocalVideoRenderer(_ renderer: RTCVideoRenderer) {
        webRTCSession.attachLocalRenderer(renderer)
    }
    
    func removeLocalVideoRenderer(_ renderer: RTCVideoRenderer) {
        webRTCSession.removeLocalRenderer(renderer)
    }
    
    // MARK: - Delegate
    
    public func webRTCIsConnected() {
        self.invalidateTimeoutTimer()
        self.reconnectTimer?.invalidate()
        
        guard !self.hasConnected else {
            hasReconnected?()
            return
        }
        
        self.hasConnected = true
        self.answerCallAction?.fulfill()
    }
    
    public func isRemoteVideoDidChange(isEnabled: Bool) {
        isRemoteVideoEnabled = isEnabled
    }
    
    public func sendingIceCandidates() {
        DispatchQueue.main.async {
            self.updateCurrentConnectionStepIfPossible(
                self.mode == .offer ? OfferStep.sendingIceCandidates : AnswerStep.sendingIceCandidates
            )
        }
    }
    
    public func iceCandidateDidSend() {
        if self.mode == .offer {
            DispatchQueue.main.async {
                self.updateCurrentConnectionStepIfPossible(
                    self.mode == .offer ? OfferStep.waitingForAnswer : AnswerStep.handlingIceCandidates
                )
            }
        }
    }
    
    public func iceCandidateDidReceive() {
        DispatchQueue.main.async {
            self.updateCurrentConnectionStepIfPossible(
                self.mode == .offer ? OfferStep.handlingIceCandidates : AnswerStep.handlingIceCandidates
            )
        }
    }
    
    public func didReceiveHangUpSignal() {
        self.hasEnded = true
        DispatchQueue.main.async { [dependencies] in
            if let currentBanner = IncomingCallBanner.current { currentBanner.dismiss() }
            guard dependencies[singleton: .appContext].isValid else { return }
            if let callVC = dependencies[singleton: .appContext].frontMostViewController as? CallVC { callVC.handleEndCallMessage() }
            if let miniCallView = MiniCallView.current { miniCallView.dismiss() }
            dependencies[singleton: .callManager].reportCurrentCallEnded(reason: .remoteEnded)
        }
    }
    
    public func dataChannelDidOpen() {
        // Send initial video status
        if (isVideoEnabled) {
            webRTCSession.turnOnVideo()
        } else {
            webRTCSession.turnOffVideo()
        }
    }
    
    public func reconnectIfNeeded() {
        setupTimeoutTimer()
        hasStartedReconnecting?()
        guard isOutgoing else { return }
        tryToReconnect()
    }
    
    private func tryToReconnect() {
        reconnectTimer?.invalidate()
        
        // Register a callback to get the current network status then remove it immediately as we only
        // care about the current status
        dependencies[cache: .libSessionNetwork].networkStatus
            .sinkUntilComplete(
                receiveValue: { [weak self, dependencies] status in
                    guard status != .connected else { return }
                    
                    self?.reconnectTimer = Timer.scheduledTimerOnMainThread(withTimeInterval: 5, repeats: false, using: dependencies) { _ in
                        self?.tryToReconnect()
                    }
                }
            )
        
        let sessionId: String = self.sessionId
        let webRTCSession: WebRTCSession = self.webRTCSession
        
        guard let thread: SessionThread = dependencies[singleton: .storage].read({ db in try SessionThread.fetchOne(db, id: sessionId) }) else {
            return
        }
        
        webRTCSession
            .sendOffer(to: thread, isRestartingICEConnection: true)
            .subscribe(on: DispatchQueue.global(qos: .userInitiated))
            .sinkUntilComplete()
    }
    
    // MARK: - Timeout
    
    public func setupTimeoutTimer() {
        invalidateTimeoutTimer()
        
        let timeInterval: TimeInterval = 60
        
        timeOutTimer = Timer.scheduledTimerOnMainThread(withTimeInterval: timeInterval, repeats: false, using: dependencies) { [weak self, dependencies] _ in
            self?.didTimeout = true
            
            dependencies[singleton: .callManager].endCall(self) { error in
                self?.timeOutTimer = nil
            }
        }
    }
    
    public func resetTimeoutTimerIfNeeded() {
        if self.timeOutTimer == nil { return }
        setupTimeoutTimer()
    }
    
    public func invalidateTimeoutTimer() {
        timeOutTimer?.invalidate()
        timeOutTimer = nil
    }
}

// MARK: - Connection Steps

extension SessionCall {
    public protocol ConnectionStep {
        var index: Int { get }
        var nextStep: ConnectionStep? { get }
    }
    
    public enum OfferStep: ConnectionStep {
        case initializing
        case sendingOffer
        case sendingIceCandidates
        case waitingForAnswer
        case handlingIceCandidates
        case connected
        
        public var index: Int {
            switch self {
                case .initializing:          return 0
                case .sendingOffer:          return 1
                case .sendingIceCandidates:  return 2
                case .waitingForAnswer:      return 3
                case .handlingIceCandidates: return 4
                case .connected:             return 5
            }
        }
        
        public var nextStep: ConnectionStep? {
            switch self {
                case .initializing:          return OfferStep.sendingOffer
                case .sendingOffer:          return OfferStep.sendingIceCandidates
                case .sendingIceCandidates:  return OfferStep.waitingForAnswer
                case .waitingForAnswer:      return OfferStep.handlingIceCandidates
                case .handlingIceCandidates: return OfferStep.connected
                case .connected:             return nil
            }
        }
    }
    
    public enum AnswerStep: ConnectionStep {
        case receivedOffer
        case sendingAnswer
        case sendingIceCandidates
        case handlingIceCandidates
        case connected
        
        public var index: Int {
            switch self {
                case .receivedOffer:         return 0
                case .sendingAnswer:         return 1
                case .sendingIceCandidates:  return 2
                case .handlingIceCandidates: return 3
                case .connected:             return 4
            }
        }
        
        public var nextStep: ConnectionStep? {
            switch self {
                case .receivedOffer:         return AnswerStep.sendingAnswer
                case .sendingAnswer:         return AnswerStep.sendingIceCandidates
                case .sendingIceCandidates:  return AnswerStep.handlingIceCandidates
                case .handlingIceCandidates: return AnswerStep.connected
                case .connected:             return nil
            }
        }
    }
    
    internal func updateCurrentConnectionStepIfPossible(_ step: ConnectionStep) {
        connectionStepsRecord[step.index] = true
        while let nextStep = currentConnectionStep.nextStep, connectionStepsRecord[nextStep.index] {
            currentConnectionStep = nextStep
            updateCallDetailedStatus?(
                mode == .offer ? Constants.call_connection_steps_sender[currentConnectionStep.index] : Constants.call_connection_steps_receiver[currentConnectionStep.index]
            )
        }
    }
}
