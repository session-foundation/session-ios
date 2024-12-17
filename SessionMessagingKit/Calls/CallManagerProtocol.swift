// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import CallKit
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    // FIXME: This will be reworked to be part of dependencies in the Groups Rebuild branch
    fileprivate static var _callManager: Atomic<CallManagerProtocol> = Atomic(NoopSessionCallManager())
    static var callManager: CallManagerProtocol { _callManager.wrappedValue }
    
    static func setCallManager(_ callManager: CallManagerProtocol) {
        _callManager = Atomic(callManager)
    }
}

// MARK: - CallManagerProtocol

public protocol CallManagerProtocol {
    var currentCall: CurrentCallProtocol? { get set }
    
    func setCurrentCall(_ call: CurrentCallProtocol?)
    func reportFakeCall(info: String)
    func reportIncomingCall(_ call: CurrentCallProtocol, callerName: String, completion: @escaping (Error?) -> Void)
    func reportCurrentCallEnded(reason: CXCallEndedReason?)
    func suspendDatabaseIfCallEndedInBackground()
    
    func startCall(_ call: CurrentCallProtocol?, completion: ((Error?) -> Void)?)
    func answerCall(_ call: CurrentCallProtocol?, completion: ((Error?) -> Void)?)
    func endCall(_ call: CurrentCallProtocol?, completion: ((Error?) -> Void)?)
    
    func showCallUIForCall(caller: String, uuid: String, mode: CallMode, interactionId: Int64?)
    func handleICECandidates(message: CallMessage, sdpMLineIndexes: [UInt32], sdpMids: [String])
    func handleAnswerMessage(_ message: CallMessage)
    
    func currentWebRTCSessionMatches(callId: String) -> Bool
    
    func dismissAllCallUI()
}
