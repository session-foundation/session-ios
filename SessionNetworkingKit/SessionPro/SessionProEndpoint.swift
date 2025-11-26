// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public extension Network.SessionPro {
    enum Endpoint: EndpointType {
        case addProPayment
        case generateProProof
        case getProRevocations
        case getProDetails
        case setPaymentRefundRequested
        
        public static var name: String { "SessionPro.Endpoint" }
        
        public var path: String {
            switch self {
                case .addProPayment: return "add_pro_payment"
                case .generateProProof: return "generate_pro_proof"
                case .getProRevocations: return "get_pro_revocations"
                case .getProDetails: return "get_pro_details"
                case .setPaymentRefundRequested: return "set_payment_refund_requested"
            }
        }
    }
}
