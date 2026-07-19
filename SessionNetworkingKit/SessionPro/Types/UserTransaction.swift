// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    struct UserTransaction: Equatable {
        /// Opaque provider slug (see `PaymentProvider.code`)
        public let providerCode: String
        /// Opaque payment identifier from the provider's purchase flow. Multi-part providers fold their
        /// parts into this one string per a backend-defined composite (e.g. Google "token|order_id");
        /// libsession treats it as opaque bytes hashed verbatim.
        public let paymentId: String

        // MARK: - Initialization

        init(providerCode: String, paymentId: String) {
            self.providerCode = providerCode
            self.paymentId = paymentId
        }

        init(_ libSessionValue: session_pro_backend_add_pro_payment_user_transaction) {
            providerCode = libSessionValue.get(\.provider_code).substring(to: libSessionValue.provider_code_count)
            paymentId = libSessionValue.get(\.payment_id).substring(to: libSessionValue.payment_id_count)
        }

        // MARK: - Functions

        func toLibSession() -> session_pro_backend_add_pro_payment_user_transaction {
            var result: session_pro_backend_add_pro_payment_user_transaction = session_pro_backend_add_pro_payment_user_transaction()
            result.set(\.provider_code, to: providerCode)
            result.provider_code_count = providerCode.count
            result.set(\.payment_id, to: paymentId)
            result.payment_id_count = paymentId.count

            return result
        }
    }
}

extension session_pro_backend_add_pro_payment_user_transaction: @retroactive CAccessible & CMutable {}
