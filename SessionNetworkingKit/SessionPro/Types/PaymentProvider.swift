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
    /// through via `.other`. The canonical slugs mirror `SESSION_PRO_BACKEND_PAYMENT_PROVIDER_CODE_*`
    /// in `pro_backend.h`; those are `static const char[]` in C (internal linkage, no exported symbol)
    /// so they don't import cleanly into Swift — we mirror the literals here and must keep them in sync.
    enum PaymentProvider: Sendable, Equatable, Hashable {
        case playStore
        case appStore
        case rangeproof
        case other(String)

        /// Canonical wire slugs — MUST match SESSION_PRO_BACKEND_PAYMENT_PROVIDER_CODE_* in pro_backend.h
        static let googlePlayCode: String = "google_play"
        static let appStoreCode: String = "app_store"
        static let rangeproofCode: String = "rangeproof"

        var code: String {
            switch self {
                case .playStore: return PaymentProvider.googlePlayCode
                case .appStore: return PaymentProvider.appStoreCode
                case .rangeproof: return PaymentProvider.rangeproofCode
                case .other(let code): return code
            }
        }

        init(code: String) {
            switch code {
                case PaymentProvider.googlePlayCode: self = .playStore
                case PaymentProvider.appStoreCode: self = .appStore
                case PaymentProvider.rangeproofCode: self = .rangeproof
                default: self = .other(code)
            }
        }
    }
}
