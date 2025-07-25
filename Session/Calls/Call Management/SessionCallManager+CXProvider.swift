// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import AVFAudio
import CallKit
import SessionUtilitiesKit

extension SessionCallManager: CXProviderDelegate {
    public func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor [weak self] in
            (self?.currentCall as? SessionCall)?.endSessionCall()
        }
    }
    
    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor [weak self] in
            if self?.startCallAction() == true {
                action.fulfill()
            }
            else {
                action.fail()
            }
        }
    }
    
    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor [weak self, appContext = dependencies[singleton: .appContext]] in
            Log.debug(.calls, "Perform CXAnswerCallAction")
            
            guard let call: SessionCall = (self?.currentCall as? SessionCall) else {
                Log.warn("[CallKit] No session call")
                return action.fail()
            }
            
            call.answerCallAction = action
            
            if appContext.isMainAppAndActive {
                self?.answerCallAction()
            }
            else {
                call.answerSessionCallInBackground()
            }
        }
    }
    
    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor [weak self] in
            Log.debug(.calls, "Perform CXEndCallAction")
            
            if self?.endCallAction() == true {
                action.fulfill()
            }
            else {
                action.fail()
            }
        }
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor [weak self] in
            Log.debug(.calls, "Perform CXSetMutedCallAction, isMuted: \(action.isMuted)")
            
            if self?.setMutedCallAction(isMuted: action.isMuted) == true {
                action.fulfill()
            }
            else {
                action.fail()
            }
        }
    }
    
    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        // TODO: [CALLS] set on hold
    }
    
    public func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        // TODO: [CALLS] handle timeout
    }
    
    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor [weak self] in
            Log.debug(.calls, "Audio session did activate.")
            
            guard let call: SessionCall = (self?.currentCall as? SessionCall) else { return }
            
            call.webRTCSession.audioSessionDidActivate(audioSession)
            if call.mode == .offer && !call.hasConnected { CallRingTonePlayer.shared.startPlayingRingTone() }
        }
    }
    
    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor [weak self] in
            Log.debug(.calls, "Audio session did deactivate.")
            
            guard let call: SessionCall = (self?.currentCall as? SessionCall) else { return }
            
            call.webRTCSession.audioSessionDidDeactivate(audioSession)
        }
    }
}

