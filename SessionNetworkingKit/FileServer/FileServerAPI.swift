// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

private typealias FileServer = Network.FileServer
private typealias Endpoint = Network.FileServer.Endpoint

public extension Network.FileServer {
    static func preparedUpload(
        data: Data,
        requestAndPathBuildTimeout: TimeInterval? = nil,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<FileUploadResponse> {
        var headers: [HTTPHeader: String] = [:]
        
        if dependencies[feature: .shortenFileTTL] {
            headers = [.fileCustomTTL: "60"]
        }
        
        return try Network.PreparedRequest(
            request: Request<Data, Endpoint>(
                endpoint: .file,
                destination: .serverUpload(
                    server: FileServer.server(using: dependencies),
                    headers: headers,
                    x25519PublicKey: FileServer.x25519PublicKey(using: dependencies),
                    fileName: nil
                ),
                body: data
            ),
            responseType: FileUploadResponse.self,
            requestTimeout: Network.fileUploadTimeout,
            requestAndPathBuildTimeout: requestAndPathBuildTimeout,
            using: dependencies
        )
    }
    
    static func preparedDownload(
        url: URL,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Data> {
        let strippedUrl: URL = try url.strippingQueryAndFragment ?? { throw NetworkError.invalidURL }()
        
        return try Network.PreparedRequest(
            request: Request<NoBody, Endpoint>(
                endpoint: .directUrl(strippedUrl),
                destination: .serverDownload(
                    url: strippedUrl,
                    x25519PublicKey: FileServer.x25519PublicKey(for: url, using: dependencies),
                    fileName: nil
                )
            ),
            responseType: Data.self,
            requestTimeout: Network.fileDownloadTimeout,
            using: dependencies
        )
    }
    
    static func preparedExtend(
        url: URL,
        ttl: TimeInterval,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<ExtendExpirationResponse> {
        let strippedUrl: URL = try url.strippingQueryAndFragment ?? { throw NetworkError.invalidURL }()
        
        return try Network.PreparedRequest(
            request: Request<NoBody, Endpoint>(
                endpoint: .extendUrl(strippedUrl),
                destination: .server(
                    method: .post,
                    url: strippedUrl,
                    headers: [.fileCustomTTL: "\(Int(floor(ttl)))"],
                    x25519PublicKey: FileServer.x25519PublicKey(for: url, using: dependencies)
                )
            ),
            responseType: ExtendExpirationResponse.self,
            using: dependencies
        )
    }
}
