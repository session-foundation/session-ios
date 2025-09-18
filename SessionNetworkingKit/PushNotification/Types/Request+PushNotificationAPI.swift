// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension Request where Endpoint == Network.PushNotification.Endpoint {
    init(
        method: HTTPMethod,
        endpoint: Endpoint,
        queryParameters: [HTTPQueryParam: String] = [:],
        headers: [HTTPHeader: String] = [:],
        body: T? = nil
    ) throws {
        self = try Request(
            endpoint: endpoint,
            destination: try .server(
                method: method,
                server: Network.PushNotification.server,
                queryParameters: queryParameters,
                headers: headers,
                x25519PublicKey: Network.PushNotification.serverPublicKey
            ),
            body: body
        )
    }
}
