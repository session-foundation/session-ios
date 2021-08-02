//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

// MARK: - NSObject

@objc
public extension NSObject {

    final var audioSession: OWSAudioSession {
        Environment.shared.audioSessionRef
    }

    static var audioSession: OWSAudioSession {
        Environment.shared.audioSessionRef
    }
    
    final var individualCallUIAdapter: CallUIAdapter {
        AppEnvironment.shared.callServiceRef.individualCallService.callUIAdapter
    }

    static var individualCallUIAdapter: CallUIAdapter {
        AppEnvironment.shared.callServiceRef.individualCallService.callUIAdapter
    }

    final var callService: CallService {
        AppEnvironment.shared.callServiceRef
    }

    static var callService: CallService {
        AppEnvironment.shared.callServiceRef
    }

    final var outboundIndividualCallInitiator: OutboundIndividualCallInitiator {
        AppEnvironment.shared.outboundIndividualCallInitiatorRef
    }

    static var outboundIndividualCallInitiator: OutboundIndividualCallInitiator {
        AppEnvironment.shared.outboundIndividualCallInitiatorRef
    }
}

public protocol Dependencies { }

public extension Dependencies {
    
    var audioSession: OWSAudioSession {
        Environment.shared.audioSessionRef
    }

    static var audioSession: OWSAudioSession {
        Environment.shared.audioSessionRef
    }

    var individualCallUIAdapter: CallUIAdapter {
        AppEnvironment.shared.callServiceRef.individualCallService.callUIAdapter
    }

    static var individualCallUIAdapter: CallUIAdapter {
        AppEnvironment.shared.callServiceRef.individualCallService.callUIAdapter
    }

    var callService: CallService {
        AppEnvironment.shared.callServiceRef
    }

    static var callService: CallService {
        AppEnvironment.shared.callServiceRef
    }

    var outboundIndividualCallInitiator: OutboundIndividualCallInitiator {
        AppEnvironment.shared.outboundIndividualCallInitiatorRef
    }

    static var outboundIndividualCallInitiator: OutboundIndividualCallInitiator {
        AppEnvironment.shared.outboundIndividualCallInitiatorRef
    }
}
