// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

private typealias FileServer = Network.FileServer
private typealias Endpoint = Network.FileServer.Endpoint

public extension Network.FileServer {
    static func preparedExtend(
        url: URL,
        customTtl: TimeInterval?,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<ExtendExpirationResponse> {
        let strippedUrl: URL = try url.strippingQueryAndFragment ?? { throw NetworkError.invalidURL }()
        
        var headers: [HTTPHeader: String] = [:]
        
        if let ttl: TimeInterval = customTtl {
            headers = [.fileCustomTTL: "\(Int(floor(ttl)))"]
        }
        
        return try Network.PreparedRequest(
            request: Request<NoBody, Endpoint>(
                endpoint: .extendUrl(strippedUrl),
                destination: .server(
                    method: .post,
                    url: strippedUrl,
                    headers: headers,
                    x25519PublicKey: FileServer.x25519PublicKey(for: url, using: dependencies)
                ),
                category: .fileSmall
            ),
            responseType: ExtendExpirationResponse.self,
            using: dependencies
        )
    }
}
