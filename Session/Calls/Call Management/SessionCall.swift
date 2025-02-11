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
    @objc static let isEnabled = true
    
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
            updateCallDetailedStatus?("Call Connected")
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
        
        let avatarData: Data? = ProfileManager.profileAvatar(db, id: sessionId)
        self.contactName = Profile.displayName(db, id: sessionId, threadVariant: .contact)
        self.profilePicture = avatarData
            .map { UIImage(data: $0) }
            .defaulting(to: PlaceholderIcon.generate(seed: sessionId, text: self.contactName, size: 300))
        self.animatedProfilePicture = avatarData
            .map { data in
                switch data.guessedImageFormat {
                    case .gif, .webp: return YYImage(data: data)
                    default: return nil
                }
            }
        
        WebRTCSession.current = self.webRTCSession
        self.webRTCSession.delegate = self
        
        if Singleton.callManager.currentCall == nil {
            Singleton.callManager.setCurrentCall(self)
        }
        else {
            SNLog("[Calls] A call is ongoing.")
        }
    }
    
    // stringlint:ignore_contents
    func reportIncomingCallIfNeeded(completion: @escaping (Error?) -> Void) {
        guard case .answer = mode else {
            Singleton.callManager.reportFakeCall(info: "Call not in answer mode")
            return
        }
        
        setupTimeoutTimer()
        Singleton.callManager.reportIncomingCall(self, callerName: contactName) { error in
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
        
        SNLog("[Calls] Did receive remote sdp.")
        remoteSDP = sdp
        if hasStartedConnecting {
            webRTCSession.handleRemoteSDP(sdp, from: sessionId) // This sends an answer message internally
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
        let timestampMs: Int64 = SnodeAPI.currentOffsetTimestampMs()
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
            authorId: getUserHexEncodedPublicKey(db),
            variant: .infoCall,
            body: String(data: messageInfoData, encoding: .utf8),
            timestampMs: timestampMs,
            expiresInSeconds: message.expiresInSeconds,
            expiresStartedAtMs: message.expiresStartedAtMs
        )
        .inserted(db)
        
        self.callInteractionId = interaction?.id
        
        self.updateCallDetailedStatus?("Creating Call")
        
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
                self?.updateCallDetailedStatus?("Sending Call Offer")
                return webRTCSession
                    .sendOffer(to: thread)
                    .retry(5)
            }
            .sinkUntilComplete(
                receiveCompletion: { [weak self] result in
                    switch result {
                        case .finished:
                            SNLog("[Calls] Offer message sent")
                            self?.updateCallDetailedStatus?("Sending Connection Candidates")
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
            self.updateCallDetailedStatus?("Answering Call")
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
        
        Storage.shared.writeAsync { [weak self] db in
            try self?.webRTCSession.endCall(db, with: sessionId)
        }
        
        hasEnded = true
    }
    
    func handleCallInitializationFailed() {
        self.endSessionCall()
        Singleton.callManager.reportCurrentCallEnded(reason: nil)
    }
    
    // MARK: - Call Message Handling
    
    public func updateCallMessage(mode: EndCallMode, using dependencies: Dependencies) {
        guard let callInteractionId: Int64 = callInteractionId else { return }
        
        let duration: TimeInterval = self.duration
        let hasStartedConnecting: Bool = self.hasStartedConnecting
        
        Storage.shared.writeAsync(
            updates: { db in
                guard let interaction: Interaction = try? Interaction.fetchOne(db, id: callInteractionId) else {
                    return
                }
                
                let updateToMissedIfNeeded: () throws -> () = {
                    let missedCallInfo: CallMessage.MessageInfo = CallMessage.MessageInfo(state: .missed)
                    
                    guard
                        let infoMessageData: Data = (interaction.body ?? "").data(using: .utf8),
                        let messageInfo: CallMessage.MessageInfo = try? JSONDecoder().decode(
                            CallMessage.MessageInfo.self,
                            from: infoMessageData
                        ),
                        messageInfo.state == .incoming,
                        let missedCallInfoData: Data = try? JSONEncoder().encode(missedCallInfo)
                    else { return }
                    
                    _ = try interaction
                        .with(body: String(data: missedCallInfoData, encoding: .utf8))
                        .saved(db)
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
            completion: { _ in
                Singleton.callManager.suspendDatabaseIfCallEndedInBackground()
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
    
    public func iceCandidateDidSend() {
        DispatchQueue.main.async {
            self.updateCallDetailedStatus?("Awaiting Recipient Answer...")
        }
    }
    
    public func iceCandidateDidReceive() {
        DispatchQueue.main.async {
            self.updateCallDetailedStatus?("Handling Connection Candidates")
        }
    }
    
    public func didReceiveHangUpSignal() {
        self.hasEnded = true
        DispatchQueue.main.async {
            if let currentBanner = IncomingCallBanner.current { currentBanner.dismiss() }
            guard Singleton.hasAppContext else { return }
            if let callVC = Singleton.appContext.frontmostViewController as? CallVC { callVC.handleEndCallMessage() }
            if let miniCallView = MiniCallView.current { miniCallView.dismiss() }
            Singleton.callManager.reportCurrentCallEnded(reason: .remoteEnded)
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
        let networkStatusCallbackId: UUID = LibSession.onNetworkStatusChanged { [weak self] status in
            guard status != .connected else { return }
            
            self?.reconnectTimer = Timer.scheduledTimerOnMainThread(withTimeInterval: 5, repeats: false) { _ in
                self?.tryToReconnect()
            }
        }
        LibSession.removeNetworkChangedCallback(callbackId: networkStatusCallbackId)
        
        let sessionId: String = self.sessionId
        let webRTCSession: WebRTCSession = self.webRTCSession
        
        guard let thread: SessionThread = Storage.shared.read({ db in try SessionThread.fetchOne(db, id: sessionId) }) else {
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
        
        timeOutTimer = Timer.scheduledTimerOnMainThread(withTimeInterval: timeInterval, repeats: false) { _ in
            self.didTimeout = true
            
            Singleton.callManager.endCall(self) { error in
                self.timeOutTimer = nil
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
