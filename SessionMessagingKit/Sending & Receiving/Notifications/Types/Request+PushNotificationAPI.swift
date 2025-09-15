// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: Request - PushNotificationAPI

public extension Request where Endpoint == PushNotificationAPI.Endpoint {
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
                server: PushNotificationAPI.server,
                queryParameters: queryParameters,
                headers: headers,
                x25519PublicKey: PushNotificationAPI.serverPublicKey
            ),
            body: body
        )
    }
}
