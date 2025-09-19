// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension Request where Endpoint == Network.SnodeAPI.Endpoint {
    init<B: Encodable>(
        endpoint: Endpoint,
        snode: LibSession.Snode,
        swarmPublicKey: String? = nil,
        body: B
    ) throws where T == SnodeRequest<B> {
        self = try Request(
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
        endpoint: Endpoint,
        swarmPublicKey: String,
        body: B,
        snodeRetrievalRetryCount: Int = Network.SnodeAPI.maxRetryCount
    ) throws where T == SnodeRequest<B> {
        self = try Request(
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
        requiresLatestNetworkTime: Bool,
        body: B,
        snodeRetrievalRetryCount: Int = Network.SnodeAPI.maxRetryCount
    ) throws where T == SnodeRequest<B>, B: Encodable & UpdatableTimestamp {
        self = try Request(
            endpoint: endpoint,
            destination: .randomSnodeLatestNetworkTimeTarget(
                swarmPublicKey: swarmPublicKey,
                snodeRetrievalRetryCount: snodeRetrievalRetryCount,
                bodyWithUpdatedTimestampMs: { timestampMs, dependencies in
                    SnodeRequest<B>(
                        endpoint: endpoint,
                        body: body.with(timestampMs: timestampMs)
                    )
                }
            ),
            body: SnodeRequest<B>(
                endpoint: endpoint,
                body: body
            )
        )
    }
}
