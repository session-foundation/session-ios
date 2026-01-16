// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension Request where Endpoint == Network.SessionPro.Endpoint {
    init(
        method: HTTPMethod,
        endpoint: Endpoint,
        queryParameters: [HTTPQueryParam: String] = [:],
        headers: [HTTPHeader: String] = [:],
        body: T? = nil,
        using dependencies: Dependencies
    ) throws {
        self = try Request(
            endpoint: endpoint,
            destination: try .server(
                method: method,
                server: Network.SessionPro.server,
                queryParameters: queryParameters,
                headers: headers,
                x25519PublicKey: Network.SessionPro.x25519PublicKey(using: dependencies)
            ),
            body: body
        )
    }
}
