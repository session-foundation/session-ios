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
        /// The account's expiry — the end of the paid term (unix seconds) — or `0` if this response carries no
        /// horizon. Advisory + unsigned (not an entitlement authority, not in the proof sig): used only to refresh
        /// the cached access expiry `E` for display / preemptive-renewal timing. Present on a successful proof and
        /// on `subscription_expired` (a now-past value); `0` otherwise.
        ///
        /// The account's own expiry, not a proof horizon, and not grace-inclusive — it is the same quantity
        /// `get_pro_status` reports as `expiry_ts`, so it is directly comparable with it and with config `E`.
        /// Coverage end is `E + G`, derived by the caller; this value never has grace folded into it.
        public let accountExpiryTimestampSeconds: UInt64

        /// Not public — read them through `accountRenewalInfo`.
        ///
        /// Trustworthy only when `outcome == .success`. On a transport or protocol failure nothing was parsed, so
        /// these hold `0`/`false` — indistinguishable from an account that genuinely has no grace and is not
        /// renewing. That is not inert: the config keys are presence-only, so writing that `false` erases a flag
        /// `get_pro_status` had learned.
        ///
        /// The type cannot express "not parsed", so the scope does — hence private, behind a success-gated accessor.
        /// A `0`/`false` that *was* parsed is a real answer; the gate exists for the values that were not.
        private let rawAccountGracePeriodSeconds: UInt64
        private let rawAccountAutoRenewing: Bool

        /// The account's grace period and renewal flag — `nil` unless this response carried a proof.
        ///
        /// They exist so a proof outcome can keep `E`, `G` and `A` coherent: this response writes `E`, and
        /// without them a proof would move the access expiry while leaving a grace period and renewal flag paired
        /// with the previous one, which makes `E + G` — the coverage end — silently meaningless.
        public var accountRenewalInfo: AccountRenewalInfo? {
            guard outcome == .success else { return nil }

            return AccountRenewalInfo(
                gracePeriodSeconds: rawAccountGracePeriodSeconds,
                autoRenewing: rawAccountAutoRenewing
            )
        }

        public struct AccountRenewalInfo: Equatable {
            public let gracePeriodSeconds: UInt64
            public let autoRenewing: Bool
        }

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

            /// Stored raw and gated on the outcome by `accountRenewalInfo`: read them through that, since a
            /// failure that parsed nothing leaves these at `0`/`false` rather than at anything the backend said.
            self.rawAccountGracePeriodSeconds = UInt64(max(0, result.account_grace_period_duration))
            self.rawAccountAutoRenewing = result.account_auto_renewing
        }
    }
}
