// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil

public extension Network.SessionPro {
    /// A payment provider, identified by its opaque wire "code" slug.
    ///
    /// libsession no longer ships a fixed provider enum — the provider is a free-form string on the
    /// wire (folded into the signed add-payment/refund hashes), so an unknown/future provider passes
    /// through via `.other`. The canonical known slugs are derived directly from libsession's
    /// `SESSION_PRO_BACKEND_PAYMENT_PROVIDER_CODE_*` C constants (the single source of truth), so a
    /// slug change in libsession flows through here with no literal to keep in sync.
    enum PaymentProvider: Sendable, Equatable, Hashable {
        case playStore
        case appStore
        case stf
        case other(String)

        /// Canonical wire slugs, derived once from libsession's `SESSION_PRO_BACKEND_PAYMENT_PROVIDER_CODE_*`
        /// C constants (the single source of truth). These are `const char* const` pointers (NOT inline
        /// `char[]` arrays), so we dereference the pointer to read the NUL-terminated string — mirroring how
        /// `SESSION_PRO_BACKEND_URL` is read. (Reading them with `withUnsafeBytes(of:)` would read the bytes
        /// of the pointer *value* instead, yielding garbage and collapsing every provider to `.other`.)
        static let googlePlayCode: String = (SESSION_PRO_BACKEND_PAYMENT_PROVIDER_CODE_GOOGLE_PLAY.map { String(cString: $0) } ?? "")
        static let appStoreCode: String = (SESSION_PRO_BACKEND_PAYMENT_PROVIDER_CODE_APP_STORE.map { String(cString: $0) } ?? "")
        static let stfCode: String = (SESSION_PRO_BACKEND_PAYMENT_PROVIDER_CODE_STF.map { String(cString: $0) } ?? "")

        var code: String {
            switch self {
                case .playStore: return PaymentProvider.googlePlayCode
                case .appStore: return PaymentProvider.appStoreCode
                case .stf: return PaymentProvider.stfCode
                case .other(let code): return code
            }
        }

        init(code: String) {
            switch code {
                case PaymentProvider.googlePlayCode: self = .playStore
                case PaymentProvider.appStoreCode: self = .appStore
                case PaymentProvider.stfCode: self = .stf
                default: self = .other(code)
            }
        }
    }
}
