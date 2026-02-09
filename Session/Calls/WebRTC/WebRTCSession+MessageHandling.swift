// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import WebRTC
import SessionMessagingKit
import SessionUtilitiesKit

extension WebRTCSession {
    
    public func handleICECandidates(_ candidate: [RTCIceCandidate]) {
        Log.info(.calls, "Received ICE candidate message.")
        self.delegate?.iceCandidateDidReceive()
        candidate.forEach { peerConnection?.add($0, completionHandler: { _ in  }) }
    }
    
    public func handleRemoteSDP(_ sdp: RTCSessionDescription, from sessionId: String) {
        Log.debug(.calls, "Received remote SDP: \(sdp.sdp).")
        
        peerConnection?.setRemoteDescription(sdp, completionHandler: { [weak self] error in
            if let error = error {
                Log.error(.calls, "Couldn't set SDP due to error: \(error).")
            }
            else {
                guard sdp.type == .offer else { return }
                
                Task(priority: .userInitiated) { [weak self] in
                    for _ in 1...5 {
                        do {
                            try await self?.sendAnswer(to: sessionId)
                            break
                        }
                        catch {}
                    }
                }
            }
        })
    }
}
