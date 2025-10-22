// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension Network.SessionPro {
    struct UserTransaction: Equatable {
        public let provider: PaymentProvider
        public let paymentId: String
        
        // MARK: - Initialization
        
        init (provider: PaymentProvider, paymentId: String) {
            self.provider = provider
            self.paymentId = paymentId
        }
        
        init(_ libSessionValue: session_pro_backend_add_pro_payment_user_transaction) {
            provider = PaymentProvider(libSessionValue.provider)
            paymentId = libSessionValue.get(\.payment_id).substring(to: libSessionValue.payment_id_count)
        }
        
        // MARK: - Functions
        
        func toLibSession() -> session_pro_backend_add_pro_payment_user_transaction {
            var result: session_pro_backend_add_pro_payment_user_transaction = session_pro_backend_add_pro_payment_user_transaction()
            result.provider = provider.libSessionValue
            result.set(\.payment_id, to: paymentId)
            result.payment_id_count = paymentId.count
            
            return result
        }
    }
}

extension session_pro_backend_add_pro_payment_user_transaction: @retroactive CAccessible & CMutable {}
