// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension Request where Endpoint == Network.SOGS.Endpoint {
    init(
        method: HTTPMethod = .get,
        endpoint: Endpoint,
        queryParameters: [HTTPQueryParam: String] = [:],
        headers: [HTTPHeader: String] = [:],
        body: T? = nil,
        category: Network.RequestCategory = .standard,
        authMethod: AuthenticationMethod,
        requestTimeout: TimeInterval = Network.defaultTimeout,
        overallTimeout: TimeInterval? = nil
    ) throws {
        guard case .community(let server, let publicKey, _, _, _) = authMethod.info else {
            throw CryptoError.signatureGenerationFailed
        }
        
        self = Request(
            endpoint: endpoint,
            destination: .server(
                method: method,
                server: server,
                queryParameters: queryParameters,
                headers: headers,
                x25519PublicKey: publicKey
            ),
            body: body,
            category: category,
            requestTimeout: requestTimeout,
            overallTimeout: overallTimeout
        )
    }
}
