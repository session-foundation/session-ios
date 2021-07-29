//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

// MARK: - NSObject

@objc
public extension NSObject {

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
