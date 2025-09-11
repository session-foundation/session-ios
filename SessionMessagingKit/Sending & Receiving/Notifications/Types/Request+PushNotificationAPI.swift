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
        body: T? = nil,
        retryCount: Int = 0
    ) {
        self = Request(
            endpoint: endpoint,
            destination: .server(
                method: method,
                server: PushNotificationAPI.server,
                queryParameters: queryParameters,
                headers: headers,
                x25519PublicKey: PushNotificationAPI.serverPublicKey
            ),
            body: body,
            retryCount: retryCount
        )
    }
}
