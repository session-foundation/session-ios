// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension Network {
    enum FileServer {
        internal static let fileServer = "http://filev2.getsession.org"
        public static let fileServerPublicKey = "da21e1d886c6fbaea313f75298bd64aab03a97ce985b46bb2dad9f2089c8ee59"
        internal static let legacyFileServer = "http://88.99.175.227"
        internal static let legacyFileServerPublicKey = "7cb31905b55cd5580c686911debf672577b3fb0bff81df4ce2d5c4cb3a7aaa69"
        
        static func fileServerPubkey(url: String? = nil) -> String {
            switch url?.contains(legacyFileServer) {
                case true: return legacyFileServerPublicKey
                default: return fileServerPublicKey
            }
        }
        
        static func isFileServerUrl(url: URL) -> Bool {
            return (
                url.absoluteString.starts(with: fileServer) ||
                url.absoluteString.starts(with: legacyFileServer)
            )
        }
        
        public static func downloadUrlString(for url: String, fileId: String) -> String {
            switch url.contains(legacyFileServer) {
                case true: return "\(fileServer)/\(Endpoint.fileIndividual(fileId).path)"
                default: return downloadUrlString(for: fileId)
            }
        }
        
        public static func downloadUrlString(for fileId: String) -> String {
            return "\(fileServer)/\(Endpoint.fileIndividual(fileId).path)"
        }
        
        public static func fileId(for downloadUrl: String?) -> String? {
            return downloadUrl
                .map { urlString -> String? in
                    urlString
                        .split(separator: "/")  // stringlint:ignore
                        .last
                        .map { String($0) }
                }
        }
    }
    
    static func preparedUpload(
        data: Data,
        requestAndPathBuildTimeout: TimeInterval? = nil,
        using dependencies: Dependencies
    ) throws -> PreparedRequest<FileUploadResponse> {
        return try PreparedRequest(
            request: Request(
                endpoint: FileServer.Endpoint.file,
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
    ) throws -> PreparedRequest<Data> {
        return try PreparedRequest(
            request: Request<NoBody, FileServer.Endpoint>(
                endpoint: FileServer.Endpoint.directUrl(url),
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
