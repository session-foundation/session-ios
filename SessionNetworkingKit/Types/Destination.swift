// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension Network {
    enum Destination: Equatable {
        public struct ServerInfo: Equatable {
            public let method: HTTPMethod
            public let server: String
            public let queryParameters: [HTTPQueryParam: String]
            public let fragmentParameters: [HTTPFragmentParam: String]
            public let headers: [HTTPHeader: String]
            public let x25519PublicKey: String
            
            // Use iOS URL processing to extract the values from `server`
            
            public var host: String? { URLComponents(string: server)?.host }
            public var scheme: String? { URLComponents(string: server)?.scheme }
            public var port: Int? { URLComponents(string: server)?.port }
            
            // MARK: - Initialization
            
            public init(
                method: HTTPMethod,
                server: String,
                queryParameters: [HTTPQueryParam: String],
                fragmentParameters: [HTTPFragmentParam: String],
                headers: [HTTPHeader: String],
                x25519PublicKey: String
            ) {
                self.method = method
                self.server = server
                self.queryParameters = queryParameters
                self.fragmentParameters = fragmentParameters
                self.headers = headers
                self.x25519PublicKey = x25519PublicKey
            }
            
            fileprivate init(
                method: HTTPMethod,
                url: URL,
                server: String?,
                queryParameters: [HTTPQueryParam: String],
                fragmentParameters: [HTTPFragmentParam: String],
                headers: [HTTPHeader: String],
                x25519PublicKey: String
            ) throws {
                self.method = method
                self.server = try {
                    if let explicitServer: String = server { return explicitServer }
                    if let urlHost: String = url.host {
                        return "\(url.scheme.map { "\($0)://" } ?? "")\(urlHost)"
                    }
                    
                    throw NetworkError.invalidURL
                }()
                self.queryParameters = queryParameters
                self.fragmentParameters = fragmentParameters
                self.headers = headers
                self.x25519PublicKey = x25519PublicKey
            }
        }
        
        case snode(LibSession.Snode, swarmPublicKey: String?)
        case randomSnode(swarmPublicKey: String)
        case server(info: ServerInfo)
        case serverUpload(info: ServerInfo, fileName: String?)
        
        // MARK: - Convenience
        
        public var method: HTTPMethod {
            switch self {
                case .server(let info), .serverUpload(let info, _): return info.method
                default: return .post   // Always POST for snode destinations
            }
        }
        
        public var server: String? {
            switch self {
                case .server(let info), .serverUpload(let info, _): return info.server
                default: return nil
            }
        }
        
        public var headers: [HTTPHeader: String] {
            switch self {
                case .server(let info), .serverUpload(let info, _): return info.headers
                case .snode, .randomSnode: return [:]
            }
        }
        
        public var queryParameters: [HTTPQueryParam: String] {
            switch self {
                case .server(let info), .serverUpload(let info, _): return info.queryParameters
                default: return [:]
            }
        }
        
        public var fragmentParameters: [HTTPFragmentParam: String] {
            switch self {
                case .server(let info), .serverUpload(let info, _): return info.fragmentParameters
                default: return [:]
            }
        }
        
        public static func server(
            method: HTTPMethod = .get,
            server: String,
            queryParameters: [HTTPQueryParam: String] = [:],
            fragmentParameters: [HTTPFragmentParam: String] = [:],
            headers: [HTTPHeader: String] = [:],
            x25519PublicKey: String
        ) -> Destination {
            return .server(info: ServerInfo(
                method: method,
                server: server,
                queryParameters: queryParameters,
                fragmentParameters: fragmentParameters,
                headers: headers,
                x25519PublicKey: x25519PublicKey
            ))
        }
        
        public static func server(
            method: HTTPMethod = .get,
            url: URL,
            queryParameters: [HTTPQueryParam: String] = [:],
            fragmentParameters: [HTTPFragmentParam: String] = [:],
            headers: [HTTPHeader: String] = [:],
            x25519PublicKey: String
        ) throws -> Destination {
            return .server(info: try ServerInfo(
                method: method,
                url: url,
                server: nil,
                queryParameters: queryParameters,
                fragmentParameters: fragmentParameters,
                headers: headers,
                x25519PublicKey: x25519PublicKey
            ))
        }
        
        public static func serverUpload(
            server: String,
            queryParameters: [HTTPQueryParam: String] = [:],
            fragmentParameters: [HTTPFragmentParam: String] = [:],
            headers: [HTTPHeader: String] = [:],
            x25519PublicKey: String,
            fileName: String?
        ) -> Destination {
            return .serverUpload(
                info: ServerInfo(
                    method: .post,
                    server: server,
                    queryParameters: queryParameters,
                    fragmentParameters: fragmentParameters,
                    headers: headers,
                    x25519PublicKey: x25519PublicKey
                ),
                fileName: fileName
            )
        }
        
        // MARK: - Convenience
        
        internal static func generatePathWithParamsAndFragments<E: EndpointType>(
            endpoint: E,
            queryParameters: [HTTPQueryParam: String],
            fragmentParameters: [HTTPFragmentParam: String]
        ) -> String {
            let pathWithParams: String = [
                "/\(endpoint.path)",
                HTTPQueryParam.string(for: queryParameters)
            ]
            .filter { !$0.isEmpty }
            .joined(separator: "?")
            
            return [
                pathWithParams,
                HTTPFragmentParam.string(for: fragmentParameters)
            ]
            .filter { !$0.isEmpty }
            .joined(separator: "#")
        }
        
        // MARK: - Equatable
        
        public static func == (lhs: Destination, rhs: Destination) -> Bool {
            switch (lhs, rhs) {
                case (.snode(let lhsSnode, let lhsSwarmPublicKey), .snode(let rhsSnode, let rhsSwarmPublicKey)):
                    return (
                        lhsSnode == rhsSnode &&
                        lhsSwarmPublicKey == rhsSwarmPublicKey
                    )
                
                case (.randomSnode(let lhsSwarmPublicKey), .randomSnode(let rhsSwarmPublicKey)):
                    return (lhsSwarmPublicKey == rhsSwarmPublicKey)
                    
                case (.server(let lhsInfo), .server(let rhsInfo)): return (lhsInfo == rhsInfo)
                
                case (.serverUpload(let lhsInfo, let lhsFileName), .serverUpload(let rhsInfo, let rhsFileName)):
                    return (
                        lhsInfo == rhsInfo &&
                        lhsFileName == rhsFileName
                    )
                
                default: return false
            }
        }
    }
}
