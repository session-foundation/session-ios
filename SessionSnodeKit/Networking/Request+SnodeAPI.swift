// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

// MARK: - SnodeTarget

internal extension Network {
    struct SnodeTarget: RequestTarget, Equatable {
        let snode: Snode
        let swarmPublicKey: String?
        
        var url: URL? { URL(string: "snode:\(snode.x25519PublicKey)") }
        var urlPathAndParamsString: String { return "" }
    }
}

// MARK: - RandomSnodeTarget

internal extension Network {
    struct RandomSnodeTarget: RequestTarget, Equatable {
        let swarmPublicKey: String
        
        var url: URL? { URL(string: "snode:\(swarmPublicKey)") }
        var urlPathAndParamsString: String { return "" }
    }
}

// MARK: - RandomSnodeLatestNetworkTimeTarget

internal extension Network {
    struct RandomSnodeLatestNetworkTimeTarget: RequestTarget, Equatable {
        let swarmPublicKey: String
        let urlRequestWithUpdatedTimestampMs: ((UInt64, Dependencies) throws -> URLRequest)
        
        var url: URL? { URL(string: "snode:\(swarmPublicKey)") }
        var urlPathAndParamsString: String { return "" }
        
        static func == (lhs: Network.RandomSnodeLatestNetworkTimeTarget, rhs: Network.RandomSnodeLatestNetworkTimeTarget) -> Bool {
            lhs.swarmPublicKey == rhs.swarmPublicKey
        }
    }
}

// MARK: Request - SnodeTarget

public extension Request {
    init(
        method: HTTPMethod = .get,
        endpoint: Endpoint,
        snode: Snode,
        headers: [HTTPHeader: String] = [:],
        body: T? = nil,
        swarmPublicKey: String?
    ) {
        self = Request(
            method: method,
            endpoint: endpoint,
            target: Network.SnodeTarget(
                snode: snode,
                swarmPublicKey: swarmPublicKey
            ),
            headers: headers,
            body: body
        )
    }
}

// MARK: Request - RandomSnodeTarget

public extension Request {
    init(
        method: HTTPMethod = .get,
        endpoint: Endpoint,
        swarmPublicKey: String,
        headers: [HTTPHeader: String] = [:],
        body: T? = nil
    ) {
        self = Request(
            method: method,
            endpoint: endpoint,
            target: Network.RandomSnodeTarget(
                swarmPublicKey: swarmPublicKey
            ),
            headers: headers,
            body: body
        )
    }
}

// MARK: Request - RandomSnodeLatestNetworkTimeTarget
    
public extension Request {
    init(
        method: HTTPMethod = .get,
        endpoint: Endpoint,
        swarmPublicKey: String,
        headers: [HTTPHeader: String] = [:],
        requiresLatestNetworkTime: Bool,
        body: T? = nil
    ) where T: UpdatableTimestamp {
        self = Request(
            method: method,
            endpoint: endpoint,
            target: Network.RandomSnodeLatestNetworkTimeTarget(
                swarmPublicKey: swarmPublicKey,
                urlRequestWithUpdatedTimestampMs: { timestampMs, dependencies in
                    try Request(
                        method: method,
                        endpoint: endpoint,
                        swarmPublicKey: swarmPublicKey,
                        headers: headers,
                        body: body?.with(timestampMs: timestampMs)
                    ).generateUrlRequest(using: dependencies)
                }
            ),
            headers: headers,
            body: body
        )
    }
}
