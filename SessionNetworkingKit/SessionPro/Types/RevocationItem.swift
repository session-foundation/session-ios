// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public struct RevocationItem: Sendable, Equatable, Hashable, Codable {
    /// Tag identifying the revoked proof (matches a proof's `revocationTag`)
    public let revocationTag: [UInt8]
    /// Unix instant (milliseconds) at which a matching proof becomes revoked; a client only treats the
    /// proof as revoked once its clock reaches this. The wire carries whole seconds — we keep the Swift
    /// domain in milliseconds (boundary conversion).
    public let effectiveTimestampMs: UInt64

    init(_ libSessionValue: session_pro_backend_pro_revocation_item) {
        revocationTag = libSessionValue.get(\.revocation_tag)
        effectiveTimestampMs = UInt64(max(0, libSessionValue.effective_ts)) * 1000
    }
}

extension session_pro_backend_pro_revocation_item: @retroactive CAccessible {}
