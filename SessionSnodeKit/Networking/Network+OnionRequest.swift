// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import SessionUtilitiesKit

public extension Network.RequestType {
    static func onionRequest(
        _ payload: Data,
        to snode: LibSession.Snode,
        swarmPublicKey: String?,
        requestTimeout: TimeInterval = Network.defaultTimeout,
        requestAndPathBuildTimeout: TimeInterval? = nil
    ) -> Network.RequestType<Data?> {
        return Network.RequestType(
            id: "onionRequest",
            url: "quic://\(snode.address)",
            method: "POST",
            body: payload,
            args: [payload, snode, swarmPublicKey, requestTimeout, requestAndPathBuildTimeout]
        ) { dependencies in
            LibSession.sendOnionRequest(
                to: Network.Destination.snode(snode),
                body: payload,
                swarmPublicKey: swarmPublicKey,
                requestTimeout: requestTimeout,
                requestAndPathBuildTimeout: requestAndPathBuildTimeout,
                using: dependencies
            )
        }
    }
    
    static func onionRequest(
        _ request: URLRequest,
        to server: String,
        with x25519PublicKey: String,
        requestTimeout: TimeInterval = Network.defaultTimeout,
        requestAndPathBuildTimeout: TimeInterval? = nil
    ) -> Network.RequestType<Data?> {
        return Network.RequestType(
            id: "onionRequest",
            url: request.url?.absoluteString,
            method: request.httpMethod,
            headers: request.allHTTPHeaderFields,
            body: request.httpBody,
            args: [request, server, x25519PublicKey, requestTimeout, requestAndPathBuildTimeout]
        ) { dependencies in
            guard let url = request.url else {
                return Fail(error: NetworkError.invalidURL).eraseToAnyPublisher()
            }
            
            return LibSession.sendOnionRequest(
                to: Network.Destination.server(
                    url: url,
                    method: (request.httpMethod.map { HTTPMethod(rawValue: $0) } ?? .get),
                    headers: request.allHTTPHeaderFields,
                    x25519PublicKey: x25519PublicKey
                ),
                body: request.httpBody,
                swarmPublicKey: nil,
                requestTimeout: requestTimeout,
                requestAndPathBuildTimeout: requestAndPathBuildTimeout,
                using: dependencies
            )
        }
    }
}
