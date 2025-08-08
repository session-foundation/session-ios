// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

// MARK: Request - SnodeAPI

public extension Request where Endpoint == SnodeAPI.Endpoint {
    init(//)<B: Encodable>(
        endpoint: SnodeAPI.Endpoint,
        snode: LibSession.Snode,
        swarmPublicKey: String? = nil,
        body: T,
        requestTimeout: TimeInterval = Network.defaultTimeout,
        overallTimeout: TimeInterval? = nil,
        retryCount: Int = 0
    ) throws {//where T == SnodeRequest<B> {
        self = try Request(
            endpoint: endpoint,
            destination: .snode(
                snode,
                swarmPublicKey: swarmPublicKey
            ),
            body: body,
            requestTimeout: requestTimeout,
            overallTimeout: overallTimeout,
            retryCount: retryCount
//            body: SnodeRequest<B>(
//                endpoint: endpoint,
//                body: body
//            )
        )
    }
    
    init(//)<B: Encodable>(
        endpoint: SnodeAPI.Endpoint,
        swarmPublicKey: String,
        body: T,
        requestTimeout: TimeInterval = Network.defaultTimeout,
        overallTimeout: TimeInterval? = nil,
        retryCount: Int = 0,
        snodeRetrievalRetryCount: Int = SnodeAPI.maxRetryCount
    ) throws {//where T == SnodeRequest<B> {
        self = try Request(
            endpoint: endpoint,
            destination: .randomSnode(
                swarmPublicKey: swarmPublicKey,
                snodeRetrievalRetryCount: snodeRetrievalRetryCount
            ),
            body: body,
            requestTimeout: requestTimeout,
            overallTimeout: overallTimeout,
            retryCount: retryCount
//            body: SnodeRequest<B>(
//                endpoint: endpoint,
//                body: body
//            )
        )
    }
    
    init(//)<B>(
        endpoint: Endpoint,
        swarmPublicKey: String,
        requiresLatestNetworkTime: Bool,
        body: T,//B,
        requestTimeout: TimeInterval = Network.defaultTimeout,
        overallTimeout: TimeInterval? = nil,
        retryCount: Int = 0,
        snodeRetrievalRetryCount: Int = SnodeAPI.maxRetryCount
    ) throws where T: UpdatableTimestamp{//where T == SnodeRequest<B>, B: Encodable & UpdatableTimestamp {
        self = try Request(
            endpoint: endpoint,
            destination: .randomSnodeLatestNetworkTimeTarget(
                swarmPublicKey: swarmPublicKey,
                snodeRetrievalRetryCount: snodeRetrievalRetryCount,
                bodyWithUpdatedTimestampMs: { timestampMs, dependencies in
                    body.with(timestampMs: timestampMs)
//                    SnodeRequest<B>(
//                        endpoint: endpoint,
//                        body: body.with(timestampMs: timestampMs)
//                    )
                }
            ),
            body: body,
            requestTimeout: requestTimeout,
            overallTimeout: overallTimeout,
            retryCount: retryCount
//            body: SnodeRequest<B>(
//                endpoint: endpoint,
//                body: body
//            )
        )
    }
}
