// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

// MARK: Request - SnodeAPI

public extension Request where Endpoint == SnodeAPI.Endpoint {
    init<B: Encodable>(
        endpoint: SnodeAPI.Endpoint,
        snode: LibSession.Snode,
        swarmPublicKey: String? = nil,
        body: B
    ) where T == SnodeRequest<B> {
        self = Request(
            endpoint: endpoint,
            destination: .snode(
                snode,
                swarmPublicKey: swarmPublicKey
            ),
            body: SnodeRequest<B>(
                endpoint: endpoint,
                body: body
            )
        )
    }
    
    init<B: Encodable>(
        endpoint: SnodeAPI.Endpoint,
        swarmPublicKey: String,
        body: B,
        snodeRetrievalRetryCount: Int = SnodeAPI.maxRetryCount
    ) where T == SnodeRequest<B> {
        self = Request(
            endpoint: endpoint,
            destination: .randomSnode(
                swarmPublicKey: swarmPublicKey,
                snodeRetrievalRetryCount: snodeRetrievalRetryCount
            ),
            body: SnodeRequest<B>(
                endpoint: endpoint,
                body: body
            )
        )
    }
    
    init<B>(
        endpoint: Endpoint,
        swarmPublicKey: String,
        headers: [HTTPHeader: String] = [:],
        requiresLatestNetworkTime: Bool,
        body: B,
        snodeRetrievalRetryCount: Int = SnodeAPI.maxRetryCount
    ) where T == SnodeRequest<B>, B: Encodable & UpdatableTimestamp {
        self = Request(
            endpoint: endpoint,
            destination: .randomSnodeLatestNetworkTimeTarget(
                swarmPublicKey: swarmPublicKey,
                snodeRetrievalRetryCount: snodeRetrievalRetryCount,
                bodyWithUpdatedTimestampMs: { timestampMs, dependencies in body.with(timestampMs: timestampMs) }
            ),
            headers: headers,
            body: SnodeRequest<B>(
                endpoint: endpoint,
                body: body
            )
        )
    }
}