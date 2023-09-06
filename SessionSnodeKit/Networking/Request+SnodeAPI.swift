// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

// MARK: - RandomSnodeTarget

internal extension HTTP {
    struct RandomSnodeTarget: RequestTarget, Equatable {
        let publicKey: String
        let requiresLatestNetworkTime: Bool
        
        var url: URL? { URL(string: "snode:\(publicKey)") }
        var urlPathAndParamsString: String { return "" }
    }
}

// MARK: Request - RandomSnodeTarget

public extension Request {
    init(
        method: HTTPMethod = .get,
        endpoint: Endpoint,
        publicKey: String,
        headers: [HTTPHeader: String] = [:],
        body: T? = nil
    ) {
        self = Request(
            method: method,
            endpoint: endpoint,
            target: HTTP.RandomSnodeTarget(
                publicKey: publicKey,
                requiresLatestNetworkTime: false // TODO: Sort this out
            ),
            headers: headers,
            body: body
        )
    }
}
