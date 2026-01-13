// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

struct Envelope: Sendable, Codable, Equatable {
    let flags: EnvelopeFlags
    let timestampMs: UInt64
    let source: [UInt8]
    let sourceDevice: UInt32
    let serverTimestamp: UInt64
    let proSignature: [UInt8]
    
    // MARK: - Initialization
    
    init(_ libSessionValue: session_protocol_envelope) {
        flags = EnvelopeFlags(libSessionValue.flags)
        timestampMs = libSessionValue.timestamp_ms
        source = libSessionValue.get(\.source)
        sourceDevice = libSessionValue.source_device
        serverTimestamp = libSessionValue.server_timestamp
        proSignature = libSessionValue.get(\.pro_sig)
    }
}

extension session_protocol_envelope: @retroactive CAccessible {}
