// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    struct AddProPaymentOrGenerateProProofResponse: Equatable {
        public let header: ResponseHeader
        public let proof: ProProof

        /// Parse the RAW response bytes via libsession. The client never inspects or assumes the wire
        /// format — the request is fetched as raw `Data` and handed straight to libsession's parser
        /// (a single parser covers both add-payment and generate-proof — each returns a proof).
        public init(parsing data: Data) {
            var result = data.withUnsafeBytes { bytes in
                session_pro_backend_pro_proof_response_parse(
                    bytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                    data.count
                )
            }
            defer { session_pro_backend_pro_proof_response_free(&result) }

            self.header = ResponseHeader(result.header)
            self.proof = ProProof(result.proof)
        }
    }
}
