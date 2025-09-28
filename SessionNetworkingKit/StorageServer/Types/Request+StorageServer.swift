// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension Request where Endpoint == Network.StorageServer.Endpoint {
    init(
        endpoint: Endpoint,
        snode: LibSession.Snode,
        swarmPublicKey: String? = nil,
        body: T,
        requestTimeout: TimeInterval = Network.defaultTimeout,
        overallTimeout: TimeInterval? = nil,
        retryCount: Int = 0
    ) {
        self = Request(
            endpoint: endpoint,
            destination: .snode(
                snode,
                swarmPublicKey: swarmPublicKey
            ),
            body: body,
            requestTimeout: requestTimeout,
            overallTimeout: overallTimeout,
            retryCount: retryCount
        )
    }
    
    init(
        endpoint: Endpoint,
        swarmPublicKey: String,
        body: T,
        requestTimeout: TimeInterval = Network.defaultTimeout,
        overallTimeout: TimeInterval? = nil,
        retryCount: Int = 0
    ) {
        self = Request(
            endpoint: endpoint,
            destination: .randomSnode(swarmPublicKey: swarmPublicKey),
            body: body,
            requestTimeout: requestTimeout,
            overallTimeout: overallTimeout,
            retryCount: retryCount
        )
    }
}
