// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    struct SetPaymentRefundRequestedResponse: Equatable {
        public let header: ResponseHeader
        public let updated: Bool

        /// Parse the RAW response bytes via libsession — the client never inspects/assumes the wire.
        public init(parsing data: Data) {
            var result = data.withUnsafeBytes { bytes in
                session_pro_backend_set_payment_refund_requested_response_parse(
                    bytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                    data.count
                )
            }
            defer { session_pro_backend_set_payment_refund_requested_response_free(&result) }

            self.header = ResponseHeader(result.header)
            self.updated = result.updated
        }
    }
}
