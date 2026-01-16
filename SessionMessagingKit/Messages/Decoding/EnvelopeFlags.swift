// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

struct EnvelopeFlags: OptionSet, Sendable, Codable, Equatable, Hashable {
    public let rawValue: UInt32
    
    public static let source: EnvelopeFlags = EnvelopeFlags(rawValue: 1 << 0)
    public static let sourceDevice: EnvelopeFlags = EnvelopeFlags(rawValue: 1 << 1)
    public static let serverTimestamp: EnvelopeFlags = EnvelopeFlags(rawValue: 1 << 2)
    public static let proSignature: EnvelopeFlags = EnvelopeFlags(rawValue: 1 << 3)
    public static let timestamp: EnvelopeFlags = EnvelopeFlags(rawValue: 1 << 4)
    
    var libSessionValue: SESSION_PROTOCOL_ENVELOPE_FLAGS {
        SESSION_PROTOCOL_ENVELOPE_FLAGS(rawValue)
    }
    
    // MARK: - Initialization
    
    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }
    
    init(_ libSessionValue: SESSION_PROTOCOL_ENVELOPE_FLAGS) {
        self = EnvelopeFlags(rawValue: libSessionValue)
    }
}
