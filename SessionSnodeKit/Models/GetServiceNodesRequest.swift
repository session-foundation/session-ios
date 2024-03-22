// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension SnodeAPI {
    public struct GetServiceNodesRequest: Encodable {
        enum CodingKeys: String, CodingKey {
            case activeOnly = "active_only"
            case limit
            case fields
        }
        
        let activeOnly: Bool
        let limit: Int?
        let fields: Fields
        
        public struct Fields: Encodable {
            enum CodingKeys: String, CodingKey {
                case publicIp = "public_ip"
                case pubkeyEd25519 = "pubkey_ed25519"
                case pubkeyX25519 = "pubkey_x25519"
                case storageLmqPort = "storage_lmq_port"
            }
            
            let publicIp: Bool
            let pubkeyEd25519: Bool
            let pubkeyX25519: Bool
            let storageLmqPort: Bool
        }
    }
}
