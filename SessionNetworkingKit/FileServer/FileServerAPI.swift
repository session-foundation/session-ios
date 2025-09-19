// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

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
        return try Network.PreparedRequest(
            request: Request<Data, Endpoint>(
                endpoint: .file,
                destination: .serverUpload(
                    server: FileServer.fileServer,
                    x25519PublicKey: FileServer.fileServerPublicKey,
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
        return try Network.PreparedRequest(
            request: Request<NoBody, Endpoint>(
                endpoint: .directUrl(url),
                destination: .serverDownload(
                    url: url,
                    x25519PublicKey: FileServer.fileServerPublicKey,
                    fileName: nil
                )
            ),
            responseType: Data.self,
            requestTimeout: Network.fileUploadTimeout,
            using: dependencies
        )
    }
}
