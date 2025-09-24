// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import SessionUtilitiesKit

public extension Network.SessionNetwork {
    // MARK: - Info
    
    /// General token info. This endpoint combines the `/price` and `/token` endpoint information.
    ///
    /// `GET/info`

    static func prepareInfo(
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Info> {
        return try Network.PreparedRequest(
            request: Request<NoBody, Network.SessionNetwork.Endpoint>(
                endpoint: Network.SessionNetwork.Endpoint.info,
                destination: .server(
                    method: .get,
                    server: Network.SessionNetwork.networkAPIServer,
                    queryParameters: [:],
                    x25519PublicKey: Network.SessionNetwork.networkAPIServerPublicKey
                )
            ),
            responseType: Info.self,
            requestAndPathBuildTimeout: Network.defaultTimeout,
            using: dependencies
        )
        .signed(with: Network.SessionNetwork.signRequest, using: dependencies)
    }
    
    // MARK: - Authentication
    
    fileprivate static func signatureHeaders(
        url: URL,
        method: HTTPMethod,
        body: Data?,
        using dependencies: Dependencies
    ) throws -> [HTTPHeader: String] {
        let timestamp: UInt64 = UInt64(floor(dependencies.dateNow.timeIntervalSince1970))
        let path: String = url.path
            .appending(url.query.map { value in "?\(value)" })
        
        let signResult: (publicKey: String, signature: [UInt8]) = try sign(
            timestamp: timestamp,
            method: method.rawValue,
            path: path,
            body: body,
            using: dependencies
        )
        
        return [
            HTTPHeader.tokenServerPubKey: signResult.publicKey,
            HTTPHeader.tokenServerTimestamp: "\(timestamp)",
            HTTPHeader.tokenServerSignature: signResult.signature.toBase64()
        ]
    }
    
    private static func sign(
        timestamp: UInt64,
        method: String,
        path: String,
        body: Data?,
        using dependencies: Dependencies
    ) throws -> (publicKey: String, signature: [UInt8]) {
        let bodyString: String? = {
            guard let bodyData: Data = body else { return nil }
            return String(data: bodyData, encoding: .utf8)
        }()
        
        guard
            !dependencies[cache: .general].ed25519SecretKey.isEmpty,
            let blinded07KeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                .versionBlinded07KeyPair(
                    ed25519SecretKey: dependencies[cache: .general].ed25519SecretKey
                )
            ),
            let signatureResult: [UInt8] = dependencies[singleton: .crypto].generate(
                .signatureVersionBlind07(
                    timestamp: timestamp,
                    method: method,
                    path: path,
                    body: bodyString,
                    ed25519SecretKey: dependencies[cache: .general].ed25519SecretKey
                )
            )
        else { throw CryptoError.signatureGenerationFailed }
        
        return (
            publicKey: SessionId(.versionBlinded07, publicKey: blinded07KeyPair.publicKey).hexString,
            signature: signatureResult
        )
    }
    
    private static func signRequest<R>(
        preparedRequest: Network.PreparedRequest<R>,
        using dependencies: Dependencies
    ) throws -> Network.Destination {
        guard
            let url: URL = try? preparedRequest.generateUrl(),
            case let .server(info) = preparedRequest.destination
        else { throw NetworkError.invalidPreparedRequest }
        
        return .server(
            info: Network.Destination.ServerInfo(
                method: info.method,
                server: info.server,
                queryParameters: info.queryParameters,
                headers: info.headers.updated(
                    with: try signatureHeaders(
                        url: url,
                        method: preparedRequest.method,
                        body: preparedRequest.body,
                        using: dependencies
                    )
                ),
                x25519PublicKey: info.x25519PublicKey
            )
        )
    }
}

