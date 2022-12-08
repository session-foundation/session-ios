// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension SnodeAPI {
    enum Endpoint: String {
        case sendMessage = "store"
        case getMessages = "retrieve"
        case deleteMessages = "delete"
        case deleteAll = "delete_all"
        case deleteAllBefore = "delete_before"
        case revokeSubkey = "revoke_subkey"
        case expire = "expire"
        case expireAll = "expire_all"
        case batch = "batch"
        case sequence = "sequence"
        
        case getInfo = "info"
        case getSwarm = "get_snodes_for_pubkey"
        
        case jsonRPCCall = "json_rpc"
        case oxenDaemonRPCCall = "oxend_request"
        
        // jsonRPCCall proxied calls
        
        case jsonGetNServiceNodes = "get_n_service_nodes"
        
        // oxenDaemonRPCCall proxied calls
        
        case daemonOnsResolve = "ons_resolve"
        case daemonGetServiceNodes = "get_service_nodes"
    }
}
