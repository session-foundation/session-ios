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
        /// The account's true, grace-inclusive entitlement end (unix seconds), or `0` if this response
        /// carries no horizon. Advisory + unsigned (not an entitlement authority, not in the proof sig) —
        /// used only to refresh the cached access expiry `E` for display / preemptive-renewal timing.
        /// Present on a successful proof and on `subscription_expired` (a now-past value); `0` otherwise.
        public let accountExpiryTimestampSeconds: UInt64

        /// The Rev 2 §4 ON_COMPLETE outcome, derived from the header. Success carries a fresh proof +
        /// account expiry; the failure slugs drive config clears; anything unrecognised — including a
        /// backend fault (`status == ERROR`) — is `transient`, i.e. fail closed non-destructively (the
        /// opaque-value discipline: an unknown `error_code` slug must never trigger a destructive write).
        public enum Outcome: Equatable {
            case success
            case subscriptionExpired
            case notSubscribed
            case revoked
            case transient
        }

        // stringlint:ignore_contents
        public var outcome: Outcome {
            guard !header.isSuccess else { return .success }

            switch header.errorCode {
                case "subscription_expired": return .subscriptionExpired
                case "not_subscribed": return .notSubscribed
                case "revoked": return .revoked
                default: return .transient
            }
        }

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
            /// Whole unix seconds; `0` = absent.
            self.accountExpiryTimestampSeconds = UInt64(max(0, result.account_expiry_ts))
        }
    }
}
