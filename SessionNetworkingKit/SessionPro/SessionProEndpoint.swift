// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:ignore

import Foundation

public extension Network.SessionPro {
    enum Endpoint: EndpointType {
        case addProPayment
        case getProProof
        case getProRevocations
        case getProStatus
        
        public static var name: String { "SessionPro.Endpoint" }
        
        public var path: String {
            switch self {
                case .addProPayment: return "add_pro_payment"
                case .getProProof: return "get_pro_proof"
                case .getProRevocations: return "get_pro_revocations"
                case .getProStatus: return "get_pro_status"
            }
        }
    }
}
