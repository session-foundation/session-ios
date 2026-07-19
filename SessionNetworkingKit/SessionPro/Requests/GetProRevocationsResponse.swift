// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    struct GetProRevocationsResponse: Equatable {
        public let header: ResponseHeader
        public let ticket: Int64
        /// Recommended seconds to wait before polling the revocation list again
        public let retryInSeconds: Int64
        /// Seconds to retain each item after first seeing it (memory-only aging)
        public let retainForSeconds: Int64
        public let items: [RevocationItem]

        /// Parse the RAW response bytes via libsession — the client never inspects/assumes the wire.
        public init(parsing data: Data) {
            var result = data.withUnsafeBytes { bytes in
                session_pro_backend_get_pro_revocations_response_parse(
                    bytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                    data.count
                )
            }
            defer { session_pro_backend_get_pro_revocations_response_free(&result) }
            
            self.header = ResponseHeader(result.header)
            self.ticket = result.ticket
            self.retryInSeconds = result.retry_in
            self.retainForSeconds = result.retain_for
            
            if result.items_count > 0 {
                self.items = (0..<result.items_count).map { index in
                    RevocationItem(result.items[index])
                }
            }
            else {
                self.items = []
            }
        }
    }
}
