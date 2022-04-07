import Foundation
import WebRTC
import SessionMessagingKit
import PromiseKit
import CallKit

public final class SessionCall: NSObject, WebRTCSessionDelegate {
    
    @objc static let isEnabled = true
    
    // MARK: Metadata Properties
    let uuid: String
    let callID: UUID // This is for CallKit
    let sessionID: String
    let mode: Mode
    var audioMode: AudioMode
    let webRTCSession: WebRTCSession
    let isOutgoing: Bool
    var remoteSDP: RTCSessionDescription? = nil
    var callMessageID: String?
    var answerCallAction: CXAnswerCallAction? = nil
    var contactName: String {
        let contact = Storage.shared.getContact(with: self.sessionID)
        return contact?.displayName(for: Contact.Context.regular) ?? "\(self.sessionID.prefix(4))...\(self.sessionID.suffix(4))"
    }
    var profilePicture: UIImage {
        if let result = OWSProfileManager.shared().profileAvatar(forRecipientId: sessionID) {
            return result
        } else {
            return Identicon.generatePlaceholderIcon(seed: sessionID, text: contactName, size: 300)
        }
    }
    
    // MARK: Control
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
    
    // MARK: Mode
    enum Mode {
        case offer
        case answer
    }
    
    // MARK: End call mode
    enum EndCallMode {
        case local
        case remote
        case unanswered
        case answeredElsewhere
    }
    
    // MARK: Audio I/O mode
    enum AudioMode {
        case earpiece
        case speaker
        case headphone
        case bluetooth
    }
    
    // MARK: Call State Properties
    var connectingDate: Date? {
        didSet {
            stateDidChange?()
            hasStartedConnectingDidChange?()
        }
    }

    var connectedDate: Date? {
        didSet {
            stateDidChange?()
            hasConnectedDidChange?()
        }
    }

    var endDate: Date? {
        didSet {
            stateDidChange?()
            hasEndedDidChange?()
        }
    }

    // Not yet implemented
    var isOnHold = false {
        didSet {
            stateDidChange?()
        }
    }

    // MARK: State Change Callbacks
    var stateDidChange: (() -> Void)?
    var hasStartedConnectingDidChange: (() -> Void)?
    var hasConnectedDidChange: (() -> Void)?
    var hasEndedDidChange: (() -> Void)?
    var remoteVideoStateDidChange: ((Bool) -> Void)?
    var hasStartedReconnecting: (() -> Void)?
    var hasReconnected: (() -> Void)?
    
    // MARK: Derived Properties
    var hasStartedConnecting: Bool {
        get { return connectingDate != nil }
        set { connectingDate = newValue ? Date() : nil }
    }

    var hasConnected: Bool {
        get { return connectedDate != nil }
        set { connectedDate = newValue ? Date() : nil }
    }

    var hasEnded: Bool {
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
    
    // MARK: Initialization
    init(for sessionID: String, uuid: String, mode: Mode, outgoing: Bool = false) {
        self.sessionID = sessionID
        self.uuid = uuid
        self.callID = UUID()
        self.mode = mode
        self.audioMode = .earpiece
        self.webRTCSession = WebRTCSession.current ?? WebRTCSession(for: sessionID, with: uuid)
        self.isOutgoing = outgoing
        WebRTCSession.current = self.webRTCSession
        super.init()
        self.webRTCSession.delegate = self
        if AppEnvironment.shared.callManager.currentCall == nil {
            AppEnvironment.shared.callManager.currentCall = self
        } else {
            SNLog("[Calls] A call is ongoing.")
        }
    }
    
    func reportIncomingCallIfNeeded(completion: @escaping (Error?) -> Void) {
        guard case .answer = mode else { return }
        setupTimeoutTimer()
        AppEnvironment.shared.callManager.reportIncomingCall(self, callerName: contactName) { error in
            completion(error)
        }
    }
    
    func didReceiveRemoteSDP(sdp: RTCSessionDescription) {
        SNLog("[Calls] Did receive remote sdp.")
        remoteSDP = sdp
        if hasStartedConnecting {
            webRTCSession.handleRemoteSDP(sdp, from: sessionID) // This sends an answer message internally
        }
    }
    
    // MARK: Actions
    func startSessionCall() {
        guard case .offer = mode else { return }
        guard let thread = TSContactThread.fetch(uniqueId: TSContactThread.threadID(fromContactSessionID: sessionID)) else { return }
        
        let message = CallMessage()
        message.sender = getUserHexEncodedPublicKey()
        message.sentTimestamp = NSDate.millisecondTimestamp()
        message.uuid = self.uuid
        message.kind = .preOffer
        let infoMessage = TSInfoMessage.from(message, associatedWith: thread)
        infoMessage.save()
        self.callMessageID = infoMessage.uniqueId
        
        var promise: Promise<Void>!
        Storage.write(with: { transaction in
            promise = self.webRTCSession.sendPreOffer(message, in: thread, using: transaction)
        }, completion: { [weak self] in
            let _ = promise.done {
                Storage.shared.write { transaction in
                    self?.webRTCSession.sendOffer(to: self!.sessionID, using: transaction as! YapDatabaseReadWriteTransaction).retainUntilComplete()
                }
                self?.setupTimeoutTimer()
            }
        })
    }
    
    func answerSessionCall() {
        guard case .answer = mode else { return }
        hasStartedConnecting = true
        if let sdp = remoteSDP {
            webRTCSession.handleRemoteSDP(sdp, from: sessionID) // This sends an answer message internally
        }
    }
    
    func answerSessionCallInBackground(action: CXAnswerCallAction) {
        answerCallAction = action
        self.answerSessionCall()
    }
    
    func endSessionCall() {
        guard !hasEnded else { return }
        webRTCSession.hangUp()
        Storage.write { transaction in
            self.webRTCSession.endCall(with: self.sessionID, using: transaction)
        }
        hasEnded = true
    }
    
    // MARK: Update call message
    func updateCallMessage(mode: EndCallMode) {
        guard let callMessageID = callMessageID else { return }
        Storage.write { transaction in
            let infoMessage = TSInfoMessage.fetch(uniqueId: callMessageID, transaction: transaction)
            if let messageToUpdate = infoMessage {
                var shouldMarkAsRead = false
                if self.duration > 0 {
                    shouldMarkAsRead = true
                } else if self.hasStartedConnecting {
                    shouldMarkAsRead = true
                } else {
                    switch mode {
                    case .local:
                        shouldMarkAsRead = true
                        fallthrough
                    case .remote:
                        fallthrough
                    case .unanswered:
                        if messageToUpdate.callState == .incoming {
                            messageToUpdate.updateCallInfoMessage(.missed, using: transaction)
                        }
                    case .answeredElsewhere:
                        shouldMarkAsRead = true
                    }
                }
                if shouldMarkAsRead {
                    messageToUpdate.markAsRead(atTimestamp: NSDate.ows_millisecondTimeStamp(), trySendReadReceipt: false, transaction: transaction)
                }
            }
        }
    }
    
    // MARK: Renderer
    func attachRemoteVideoRenderer(_ renderer: RTCVideoRenderer) {
        webRTCSession.attachRemoteRenderer(renderer)
    }
    
    func removeRemoteVideoRenderer(_ renderer: RTCVideoRenderer) {
        webRTCSession.removeRemoteRenderer(renderer)
    }
    
    func attachLocalVideoRenderer(_ renderer: RTCVideoRenderer) {
        webRTCSession.attachLocalRenderer(renderer)
    }
    
    // MARK: Delegate
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
    
    public func didReceiveHangUpSignal() {
        self.hasEnded = true
        DispatchQueue.main.async {
            if let currentBanner = IncomingCallBanner.current { currentBanner.dismiss() }
            if let callVC = CurrentAppContext().frontmostViewController() as? CallVC { callVC.handleEndCallMessage() }
            if let miniCallView = MiniCallView.current { miniCallView.dismiss() }
            AppEnvironment.shared.callManager.reportCurrentCallEnded(reason: .remoteEnded)
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
        if SSKEnvironment.shared.reachabilityManager.isReachable {
            Storage.write { transaction in
                self.webRTCSession.sendOffer(to: self.sessionID, using: transaction, isRestartingICEConnection: true).retainUntilComplete()
            }
        } else {
            reconnectTimer = Timer.scheduledTimerOnMainThread(withTimeInterval: 5, repeats: false) { _ in
                self.tryToReconnect()
            }
        }
    }
    
    // MARK: Timeout
    public func setupTimeoutTimer() {
        invalidateTimeoutTimer()
        let timeInterval: TimeInterval = hasConnected ? 60 : 30
        timeOutTimer = Timer.scheduledTimerOnMainThread(withTimeInterval: timeInterval, repeats: false) { _ in
            self.didTimeout = true
            AppEnvironment.shared.callManager.endCall(self) { error in
                self.timeOutTimer = nil
            }
        }
    }
    
    public func invalidateTimeoutTimer() {
        timeOutTimer?.invalidate()
        timeOutTimer = nil
    }
}