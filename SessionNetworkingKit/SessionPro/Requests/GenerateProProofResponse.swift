// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    /// Parsed `generate_pro_proof` response. Redemption is implicit now (there's no `/add_pro_payment`);
    /// the backend binds an account's unbound payments on any master-signed request, so a `generate_pro_proof`
    /// is all the client sends after a purchase — this is the sole consumer of libsession's proof parser.
    struct GenerateProProofResponse: Equatable {
        public let header: ResponseHeader
        public let proof: ProProof

        /// Parse the RAW response bytes via libsession. The client never inspects or assumes the wire
        /// format — the request is fetched as raw `Data` and handed straight to libsession's parser.
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
