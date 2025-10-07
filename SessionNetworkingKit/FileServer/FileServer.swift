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

// MARK: - Dev Settings

public extension FeatureStorage {
    static let customFileServer: FeatureConfig<Network.FileServer.Custom> = Dependencies.create(
        identifier: "customFileServer"
    )
}

public extension Network.FileServer {
    struct Custom: Sendable, Equatable, Codable, FeatureOption {
        public typealias RawValue = String
        
        private struct Values: Equatable, Codable {
            public let url: String
            public let pubkey: String
        }
        
        public static let defaultOption: Custom = Custom(
            url: "",
            pubkey: ""
        )
        
        public let title: String = "Custom File Server"
        public let subtitle: String? = nil
        private let values: Values
        
        public var url: String { values.url }
        public var pubkey: String { values.pubkey }
        public var isEmpty: Bool {
            values.url.isEmpty &&
            values.pubkey.isEmpty
        }
        public var isValid: Bool {
            let pubkeyValid: Bool = (
                Hex.isValid(values.pubkey) &&
                values.pubkey.count == 64
            )
            
            return (pubkeyValid && URL(string: url) != nil)
        }
        
        /// This is needed to conform to `FeatureOption` so it can be saved to `UserDefaults`
        public var rawValue: String {
            (try? JSONEncoder().encode(values)).map { String(data: $0, encoding: .utf8) } ?? ""
        }
        
        // MARK: - Initialization
        
        public init(url: String, pubkey: String) {
            self.values = Values(url: url, pubkey: pubkey)
        }
        
        public init?(rawValue: String) {
            guard
                let data: Data = rawValue.data(using: .utf8),
                let decodedValues: Values = try? JSONDecoder().decode(Values.self, from: data)
            else { return nil }
            
            self.values = decodedValues
        }
        
        // MARK: - Functions
        
        public func with(
            url: String? = nil,
            pubkey: String? = nil
        ) -> Custom {
            return Custom(
                url: (url ?? self.values.url),
                pubkey: (pubkey ?? self.values.pubkey)
            )
        }
        
        // MARK: - Equality
        
        public static func == (lhs: Custom, rhs: Custom) -> Bool {
            return (lhs.values == rhs.values)
        }
    }
}
