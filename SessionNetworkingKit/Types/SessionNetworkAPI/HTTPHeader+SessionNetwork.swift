// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

public extension HTTPHeader {
    static let tokenServerPubKey: HTTPHeader = "X-FS-Pubkey"
    static let tokenServerTimestamp: HTTPHeader = "X-FS-Timestamp"
    static let tokenServerSignature: HTTPHeader = "X-FS-Signature"
}
