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
        var headers: [HTTPHeader: String] = [:]
                
        if dependencies[feature: .shortenFileTTL] {
            headers = [.fileCustomTTL : "60"]
        }
        
        return try Network.PreparedRequest(
            request: Request<Data, Endpoint>(
                endpoint: .file,
                destination: .serverUpload(
                    server: FileServer.fileServer,
                    headers: headers,
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
        serverPubkey: String,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Data> {
        return try Network.PreparedRequest(
            request: Request<NoBody, Endpoint>(
                endpoint: .directUrl(url),
                destination: .serverDownload(
                    url: url,
                    x25519PublicKey: serverPubkey,
                    fileName: nil
                )
            ),
            responseType: Data.self,
            requestTimeout: Network.fileDownloadTimeout,
            using: dependencies
        )
    }
    
    static func preparedExtend(
        fileId: String,
        ttl: TimeInterval,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<FileUploadResponse> {
        return try Network.PreparedRequest(
            request: Request<NoBody, Endpoint>(
                endpoint: .extend(fileId),
                destination: .server(
                    method: .post,
                    server: FileServer.fileServer,
                    headers: [.fileCustomTTL: "\(ttl)"],
                    x25519PublicKey: FileServer.fileServerPublicKey
                )
            ),
            responseType: FileUploadResponse.self,
            using: dependencies
        )
    }
    
    static func preparedExtend(
        url: URL,
        ttl: TimeInterval,
        serverPubkey: String,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<FileUploadResponse> {
        return try Network.PreparedRequest(
            request: Request<NoBody, Endpoint>(
                endpoint: .extendUrl(url),
                destination: .server(
                    method: .post,
                    url: url,
                    headers: [.fileCustomTTL: "\(ttl)"],
                    x25519PublicKey: serverPubkey
                )
            ),
            responseType: FileUploadResponse.self,
            using: dependencies
        )
    }
}
