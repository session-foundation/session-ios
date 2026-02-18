// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

public extension Network.SessionPro {
    struct ResponseHeader: Equatable {
        public let status: UInt32
        public let errors: [String]
        public var isSuccess: Bool {
            errors.isEmpty || status == AddProPaymentResponseStatus.alreadyRedeemed.libSessionValue.rawValue
        }
        public var needsRefreshProProof: Bool {
            status != AddProPaymentResponseStatus.alreadyRedeemed.libSessionValue.rawValue
        }
        
        init(_ libSessionValue: session_pro_backend_response_header) {
            status = libSessionValue.status
            errors = (0..<libSessionValue.errors_count).compactMap { index in
                String(
                    pointer: libSessionValue.errors[index].data,
                    length: libSessionValue.errors[index].size,
                    encoding: .utf8
                )
            }
        }
    }
}
