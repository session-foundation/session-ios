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
        /// C constants (the single source of truth).
        static let googlePlayCode: String = cString(SESSION_PRO_BACKEND_PAYMENT_PROVIDER_CODE_GOOGLE_PLAY)
        static let appStoreCode: String = cString(SESSION_PRO_BACKEND_PAYMENT_PROVIDER_CODE_APP_STORE)
        static let stfCode: String = cString(SESSION_PRO_BACKEND_PAYMENT_PROVIDER_CODE_STF)

        /// libsession exposes those constants as fixed-size `CChar` tuples (`static const char[]`);
        /// read the NUL-terminated bytes into a Swift `String`.
        private static func cString<T>(_ cArray: T) -> String {
            withUnsafeBytes(of: cArray) { raw in
                raw.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) } ?? ""
            }
        }

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
