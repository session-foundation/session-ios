// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import WebRTC
import SessionNetworkingKit
import SessionMessagingKit
import SessionUtilitiesKit

public protocol WebRTCSessionDelegate: AnyObject {
    var uuid: String { get }
    var videoCapturer: RTCVideoCapturer { get }
    
    func webRTCIsConnected()
    func isRemoteVideoDidChange(isEnabled: Bool)
    func sendingIceCandidates()
    func iceCandidateDidSend()
    func iceCandidateDidReceive()
    func dataChannelDidOpen()
    func didReceiveHangUpSignal()
    func reconnectIfNeeded()
}

/// See https://webrtc.org/getting-started/overview for more information.
public final class WebRTCSession: NSObject, RTCPeerConnectionDelegate {
    private let dependencies: Dependencies
    public weak var delegate: WebRTCSessionDelegate?
    public let uuid: String
    private let contactSessionId: String
    private var queuedOutgoingICECandidates: [RTCIceCandidate] = []
    public var pendingIncomingICECandidates: [RTCIceCandidate] = []
    private var iceCandidateSendTimer: Timer?
    
    private lazy var defaultICEServer: TurnServerInfo? = {
        guard
            let url = Bundle.main.url(forResource: "Session-Turn-Server", withExtension: nil),  // stringlint:ignroe
                let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data, options: [ .fragmentsAllowed ]) as? JSON
        else { return nil }
        return TurnServerInfo(attributes: json, random: 2)
    }()
    
    internal lazy var factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let videoEncoderFactory = RTCDefaultVideoEncoderFactory()
        let videoDecoderFactory = RTCDefaultVideoDecoderFactory()
        return RTCPeerConnectionFactory(encoderFactory: videoEncoderFactory, decoderFactory: videoDecoderFactory)
    }()
    
    /// Represents a WebRTC connection between the user and a remote peer. Provides methods to connect to a
    /// remote peer, maintain and monitor the connection, and close the connection once it's no longer needed.
    internal lazy var peerConnection: RTCPeerConnection? = {
        let configuration = RTCConfiguration()
        if let defaultICEServer = defaultICEServer {
            configuration.iceServers = [ RTCIceServer(urlStrings: defaultICEServer.urls, username: defaultICEServer.username, credential: defaultICEServer.password) ]
        }
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: [:], optionalConstraints: [:])
        return factory.peerConnection(with: configuration, constraints: constraints, delegate: self)
    }()
    
    // Audio
    internal lazy var audioSource: RTCAudioSource = {
        let constraints = RTCMediaConstraints(mandatoryConstraints: [:], optionalConstraints: [:])
        return factory.audioSource(with: constraints)
    }()
    
    internal lazy var audioTrack: RTCAudioTrack = {
        return factory.audioTrack(with: audioSource, trackId: Self.Constants.audio_track_id)
    }()
    
    // Video
    public lazy var localVideoSource: RTCVideoSource = {
        let result = factory.videoSource()
        result.adaptOutputFormat(toWidth: 360, height: 780, fps: 30)
        return result
    }()
    
    internal lazy var localVideoTrack: RTCVideoTrack = {
        return factory.videoTrack(with: localVideoSource, trackId: Self.Constants.local_video_track_id)
    }()
    
    internal lazy var remoteVideoTrack: RTCVideoTrack? = {
        return peerConnection?.transceivers.first { $0.mediaType == .video }?.receiver.track as? RTCVideoTrack
    }()
    
    // Data Channel
    internal var dataChannel: RTCDataChannel?
    
    // MARK: - Error
    
    public enum WebRTCSessionError: LocalizedError {
        case noThread
        case failedToCorrectDescription
        
        // stringlint:ignore_contents
        public var errorDescription: String? {
            switch self {
                case .noThread: return "Couldn't find thread for contact."
                case .failedToCorrectDescription: return "Failed to correct description."
            }
        }
    }
    
    // MARK: Initialization
    public static var current: WebRTCSession?
    
    public init(for contactSessionId: String, with uuid: String, using dependencies: Dependencies) {
        RTCAudioSession.sharedInstance().useManualAudio = true
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        
        self.contactSessionId = contactSessionId
        self.uuid = uuid
        self.dependencies = dependencies
        
        super.init()
        Log.info(.calls, "ICE Severs: \(defaultICEServer?.urls ?? []) for call: \(uuid)")
        
        let mediaStreamTrackIDS = [Self.Constants.media_stream_track_id]
        
        peerConnection?.add(audioTrack, streamIds: mediaStreamTrackIDS)
        peerConnection?.add(localVideoTrack, streamIds: mediaStreamTrackIDS)
        
        // Configure audio session
        configureAudioSession()
        
        // Data channel
        if let dataChannel = createDataChannel() {
            dataChannel.delegate = self
            self.dataChannel = dataChannel
        }
    }
    
    // MARK: - Signaling
    
    public func sendPreOffer(
        message: CallMessage,
        threadId: String,
        interactionId: Int64?,
        authMethod: AuthenticationMethod
    ) async throws {
        Log.info(.calls, "Sending pre-offer message (\(uuid)).")
        
        try await MessageSender.send(
            message: message,
            to: .contact(publicKey: threadId),
            namespace: .default,
            interactionId: interactionId,
            attachments: nil,
            authMethod: authMethod,
            onEvent: MessageSender.standardEventHandling(using: dependencies),
            using: dependencies
        )
        
        Log.info(.calls, "Pre-offer message has been sent (\(uuid)).")
    }
    
    public func sendOffer(
        to thread: SessionThread,
        isRestartingICEConnection: Bool = false
    ) async throws {
        Log.info(.calls, "Sending offer message (\(uuid)).")
        let uuid: String = self.uuid
        let mediaConstraints: RTCMediaConstraints = mediaConstraints(isRestartingICEConnection)
        
        return try await withCheckedThrowingContinuation { [weak self, dependencies] continuation in
            self?.peerConnection?.offer(for: mediaConstraints) { [dependencies] sdp, error in
                guard error == nil else { return }
                
                guard let sdp: RTCSessionDescription = self?.correctSessionDescription(sdp: sdp) else {
                    preconditionFailure()
                }
                
                self?.peerConnection?.setLocalDescription(sdp) { error in
                    if let error = error {
                        Log.error(.calls, "Couldn't initiate call (\(uuid)) due to error: \(error).")
                        return continuation.resume(throwing: error)
                    }
                        
                    /// Only send after `setLocalDescription` succeeds
                    Task(priority: .userInitiated) { [dependencies] in
                        do {
                            let disappearingMessagesConfig: DisappearingMessagesConfiguration? = try? await dependencies[singleton: .storage].read { db in
                                try DisappearingMessagesConfiguration.fetchOne(db, id: thread.id)
                            }
                            let authMethod: AuthenticationMethod = try Authentication.with(
                                swarmPublicKey: thread.id,
                                using: dependencies
                            )
                            try await MessageSender.send(
                                message: CallMessage(
                                    uuid: uuid,
                                    kind: .offer,
                                    sdps: [ sdp.sdp ],
                                    sentTimestampMs: dependencies.networkOffsetTimestampMs()
                                )
                                .with(disappearingMessagesConfig?.forcedWithDisappearAfterReadIfNeeded()),
                                to: .contact(publicKey: thread.id),
                                namespace: .default,
                                interactionId: nil,
                                attachments: nil,
                                authMethod: authMethod,
                                onEvent: MessageSender.standardEventHandling(using: dependencies),
                                using: dependencies
                            )
                            
                            continuation.resume(returning: ())
                        }
                        catch {
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }
    
    public func sendAnswer(to sessionId: String) async throws {
        Log.info(.calls, "Sending answer message (\(uuid)).")
        let uuid: String = self.uuid
        let mediaConstraints: RTCMediaConstraints = mediaConstraints(false)
        
        let disappearingMessagesConfig: DisappearingMessagesConfiguration? = try await dependencies[singleton: .storage].read { db in
            /// Ensure a thread exists for the `sessionId` and that it's a `contact` thread
            guard
                SessionThread
                    .filter(id: sessionId)
                    .filter(SessionThread.Columns.variant == SessionThread.Variant.contact)
                    .isNotEmpty(db)
            else { throw WebRTCSessionError.noThread }
            
            return try DisappearingMessagesConfiguration.fetchOne(db, id: sessionId)
        }
        let authMethod: AuthenticationMethod = try Authentication.with(
            swarmPublicKey: sessionId,
            using: dependencies
        )
        
        return try await withCheckedThrowingContinuation { [weak self, dependencies] continuation in
            self?.peerConnection?.answer(for: mediaConstraints) { [weak self, dependencies] sdp, error in
                if let error = error {
                    continuation.resume(throwing: error)
                    return
                }
                
                guard let sdp: RTCSessionDescription = self?.correctSessionDescription(sdp: sdp) else {
                    return continuation.resume(throwing: WebRTCSessionError.failedToCorrectDescription)
                }
                
                self?.peerConnection?.setLocalDescription(sdp) { error in
                    if let error = error {
                        Log.error(.calls, "Couldn't accept call (\(uuid)) due to error: \(error).")
                        return continuation.resume(throwing: error)
                    }
                    
                    /// Only send after `setLocalDescription` succeeds
                    Task(priority: .userInitiated) { [dependencies] in
                        do {
                            try await MessageSender.send(
                                message: CallMessage(
                                    uuid: uuid,
                                    kind: .answer,
                                    sdps: [ sdp.sdp ]
                                )
                                .with(disappearingMessagesConfig?.forcedWithDisappearAfterReadIfNeeded()),
                                to: .contact(publicKey: sessionId),
                                namespace: .default,
                                interactionId: nil,
                                attachments: nil,
                                authMethod: authMethod,
                                onEvent: MessageSender.standardEventHandling(using: dependencies),
                                using: dependencies
                            )
                            continuation.resume(returning: ())
                        }
                        catch { continuation.resume(throwing: error) }
                    }
                }
            }
        }
    }
    
    private func queueICECandidateForSending(_ candidate: RTCIceCandidate) {
        queuedOutgoingICECandidates.append(candidate)
        DispatchQueue.main.async {
            self.iceCandidateSendTimer?.invalidate()
            self.iceCandidateSendTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { _ in
                self.sendICECandidates()
            }
        }
    }
    
    private func sendICECandidates() {
        self.delegate?.sendingIceCandidates()
        let candidates: [RTCIceCandidate] = self.queuedOutgoingICECandidates
        let uuid: String = self.uuid
        let contactSessionId: String = self.contactSessionId
        
        // Empty the queue
        self.queuedOutgoingICECandidates.removeAll()
        
        Task(priority: .userInitiated) { [weak self, dependencies] in
            do {
                let disappearingMessagesConfig: DisappearingMessagesConfiguration? = try await dependencies[singleton: .storage].read { db in
                    /// Ensure a thread exists for the `sessionId` and that it's a `contact` thread
                    guard
                        SessionThread
                            .filter(id: contactSessionId)
                            .filter(SessionThread.Columns.variant == SessionThread.Variant.contact)
                            .isNotEmpty(db)
                    else { throw WebRTCSessionError.noThread }
                    
                    return try DisappearingMessagesConfiguration.fetchOne(db, id: contactSessionId)
                }
                let authMethod: AuthenticationMethod = try Authentication.with(
                    swarmPublicKey: contactSessionId,
                    using: dependencies
                )
                
                Log.info(.calls, "Batch sending \(candidates.count) ICE candidates (\(uuid)).")
                let message: CallMessage = CallMessage(
                    uuid: uuid,
                    kind: .iceCandidates(
                        sdpMLineIndexes: candidates.map { UInt32($0.sdpMLineIndex) },
                        sdpMids: candidates.map { $0.sdpMid! }
                    ),
                    sdps: candidates.map { $0.sdp }
                )
                .with(disappearingMessagesConfig?.forcedWithDisappearAfterReadIfNeeded())
                
                for attempt in 1...5 {
                    do {
                        try await MessageSender.send(
                            message: message,
                            to: .contact(publicKey: contactSessionId),
                            namespace: .default,
                            interactionId: nil,
                            attachments: nil,
                            authMethod: authMethod,
                            onEvent: MessageSender.standardEventHandling(using: dependencies),
                            using: dependencies
                        )
                        break
                    }
                    catch {
                        guard attempt == 5 else { continue }
                        throw error
                    }
                }
                
                Log.info(.calls, "ICE candidates sent (\(uuid))")
                self?.delegate?.iceCandidateDidSend()
            }
            catch {
                Log.error(.calls, "Failed to send ICE candidates (\(uuid)) due to error: \(error)")
            }
        }
    }
    
    public func endCall(with sessionId: String) {
        Task(priority: .userInitiated) { [uuid, dependencies] in
            do {
                let disappearingMessagesConfig: DisappearingMessagesConfiguration? = try await dependencies[singleton: .storage].read { db in
                    /// Ensure a thread exists for the `sessionId` and that it's a `contact` thread
                    guard
                        SessionThread
                            .filter(id: sessionId)
                            .filter(SessionThread.Columns.variant == SessionThread.Variant.contact)
                            .isNotEmpty(db)
                    else { throw WebRTCSessionError.noThread }
                    
                    return try DisappearingMessagesConfiguration.fetchOne(db, id: sessionId)
                }
                let authMethod: AuthenticationMethod = try Authentication.with(
                    swarmPublicKey: sessionId,
                    using: dependencies
                )
                
                Log.info(.calls, "Sending end call message (\(uuid)).")
                let message: CallMessage = CallMessage(
                    uuid: uuid,
                    kind: .endCall,
                    sdps: []
                )
                .with(disappearingMessagesConfig?.forcedWithDisappearAfterReadIfNeeded())
                
                for attempt in 1...5 {
                    do {
                        try await MessageSender.send(
                            message: message,
                            to: .contact(publicKey: sessionId),
                            namespace: .default,
                            interactionId: nil,
                            attachments: nil,
                            authMethod: authMethod,
                            onEvent: MessageSender.standardEventHandling(using: dependencies),
                            using: dependencies
                        )
                        break
                    }
                    catch {
                        guard attempt == 5 else { continue }
                        throw error
                    }
                }
                
                Log.info(.calls, "End call message sent (\(uuid))")
            }
            catch {
                Log.error(.calls, "Error sending End call message due to error: \(error)")
            }
        }
    }
    
    public func dropConnection() {
        peerConnection?.close()
    }
    
    private func mediaConstraints(_ isRestartingICEConnection: Bool) -> RTCMediaConstraints {
        var mandatory: [String:String] = [
            kRTCMediaConstraintsOfferToReceiveAudio : kRTCMediaConstraintsValueTrue,
            kRTCMediaConstraintsOfferToReceiveVideo : kRTCMediaConstraintsValueTrue,
        ]
        if isRestartingICEConnection { mandatory[kRTCMediaConstraintsIceRestart] = kRTCMediaConstraintsValueTrue }
        let optional: [String:String] = [:]
        return RTCMediaConstraints(mandatoryConstraints: mandatory, optionalConstraints: optional)
    }
    
    // stringlint:ignore_contents
    private func correctSessionDescription(sdp: RTCSessionDescription?) -> RTCSessionDescription? {
        guard let sdp = sdp else { return nil }
        let cbrSdp = sdp.sdp.description.replace(regex: "(a=fmtp:111 ((?!cbr=).)*)\r?\n", with: "$1;cbr=1\r\n")
        let finalSdp = cbrSdp.replace(regex: ".+urn:ietf:params:rtp-hdrext:ssrc-audio-level.*\r?\n", with: "")
        return RTCSessionDescription(type: sdp.type, sdp: finalSdp)
    }
    
    // MARK: Peer connection delegate
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCSignalingState) {
        Log.info(.calls, "Signaling state changed to: \(state).")
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        Log.info(.calls, "Peer connection did add stream.")
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {
        Log.info(.calls, "Peer connection did remove stream.")
    }
    
    public func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {
        Log.info(.calls, "Peer connection should negotiate.")
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCIceConnectionState) {
        Log.info(.calls, "ICE connection state changed to: \(state).")
        if state == .connected {
            delegate?.webRTCIsConnected()
        } else if state == .disconnected {
            if self.peerConnection?.signalingState == .stable {
                delegate?.reconnectIfNeeded()
            }
        }
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didChange state: RTCIceGatheringState) {
        Log.info(.calls, "ICE gathering state changed to: \(state).")
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        queueICECandidateForSending(candidate)
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {
        Log.info(.calls, "\(candidates.count) ICE candidate(s) removed.")
    }
    
    public func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {
        Log.info(.calls, "Data channel opened.")
    }
}

extension WebRTCSession {
    public func configureAudioSession() {
        let audioSession = RTCAudioSession.sharedInstance()
        audioSession.lockForConfiguration()
        do {
            try audioSession.setCategory(
                .playAndRecord,
                mode: .videoChat,
                options: [.allowBluetooth, .allowBluetoothA2DP]
            )
            try audioSession.setActive(true)
        } catch let error {
            Log.error(.calls, "Couldn't set up WebRTC audio session due to error: \(error)")
        }
        audioSession.unlockForConfiguration()
    }
    
    public func audioSessionDidActivate(_ audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidActivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = true
        configureAudioSession()
    }
    
    public func audioSessionDidDeactivate(_ audioSession: AVAudioSession) {
        RTCAudioSession.sharedInstance().audioSessionDidDeactivate(audioSession)
        RTCAudioSession.sharedInstance().isAudioEnabled = false
    }
    
    public func mute() {
        audioTrack.isEnabled = false
    }
    
    public func unmute() {
        audioTrack.isEnabled = true
    }
    
    public func turnOffVideo() {
        localVideoTrack.isEnabled = false
        sendJSON([Self.Constants.video: false])
    }
    
    public func turnOnVideo() {
        localVideoTrack.isEnabled = true
        sendJSON([Self.Constants.video: true])
    }
    
    public func hangUp() {
        sendJSON([Self.Constants.hang_up: true])
    }
}
