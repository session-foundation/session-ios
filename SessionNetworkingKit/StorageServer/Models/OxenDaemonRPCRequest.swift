// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension Network.SnodeAPI {
    struct OxenDaemonRPCRequest<T: Encodable>: Encodable {
        private enum CodingKeys: String, CodingKey {
            case endpoint
            case body = "params"
        }
        
        private let endpoint: String
        private let body: T
        
        public init(
            endpoint: Network.SnodeAPI.Endpoint,
            body: T
        ) {
            self.endpoint = endpoint.path
            self.body = body
        }
    }
}
