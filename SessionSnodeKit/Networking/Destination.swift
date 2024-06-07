// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension Network {
    enum Destination: CustomStringConvertible {
        case snode(LibSession.Snode)
        case server(
            url: URL,
            method: HTTPMethod,
            headers: [HTTPHeader: String]?,
            x25519PublicKey: String
        )
        
        public var description: String {
            switch self {
                case .snode(let snode): return "Service node \(snode.address)"
                case .server(let url, _, _, _): return url.host.defaulting(to: "Unknown Host")
            }
        }
    }
}
