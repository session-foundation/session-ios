// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import WebRTC
import SessionMessagingKit
import SessionUtilitiesKit

extension WebRTCSession {
    
    public func handleICECandidates(_ candidates: [RTCIceCandidate]) {
        let uuid: String = (self.delegate?.uuid ?? "N/A")   // stringlint:ignore
        Log.info(.calls, "Received ICE candidate message (\(uuid)).")
        self.delegate?.iceCandidateDidReceive()
        
        if peerConnection?.remoteDescription != nil {
            candidates.forEach { candidate in
                peerConnection?.add(candidate, completionHandler: { error in
                    guard let error else { return }
                    
                    Log.info(.calls, "Failed to add candidate to peer connection for call (\(uuid)) due to error: \(error).")
                })
            }
        }
        else {
            self.pendingIncomingICECandidates.append(contentsOf: candidates)
        }
    }
    
    public func handleRemoteSDP(_ sdp: RTCSessionDescription, from sessionId: String) {
        Log.debug(.calls, "Received remote SDP: \(sdp.sdp).")
        
        peerConnection?.setRemoteDescription(sdp, completionHandler: { [weak self] error in
            if let error = error {
                Log.error(.calls, "Couldn't set SDP due to error: \(error).")
                return
            }
            
            // Drain buffered ICE candidates
            self?.pendingIncomingICECandidates.forEach { candidate in
                self?.peerConnection?.add(candidate) { _ in }
            }
            self?.pendingIncomingICECandidates.removeAll()
            
            guard sdp.type == .offer else { return }
            
            Task(priority: .userInitiated) { [weak self] in
                for _ in 1...5 {
                    guard
                        let self,
                        let pc = self.peerConnection,
                        pc.signalingState != .closed,
                        pc.iceConnectionState != .closed,
                        pc.iceConnectionState != .failed
                    else { break } // terminal state — stop retrying
                    
                    do {
                        try await self.sendAnswer(to: sessionId)
                        break
                    }
                    catch {}
                }
            }
        })
    }
}
