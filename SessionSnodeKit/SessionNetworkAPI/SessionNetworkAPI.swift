// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit

public enum SessionNetworkAPI {
    public static let workQueue = DispatchQueue(label: "SessionNetworkAPI.workQueue", qos: .userInitiated)
    public static let client = HTTPClient()
    
    // MARK: - Info
    
    /// General token info. This endpoint combines the `/price` and `/token` endpoint information.
    ///
    /// `GET/info`

    public static func prepareInfo(
        _ db: Database,
        using dependencies: Dependencies
    ) throws -> Network.PreparedRequest<Info> {
        return try Network.PreparedRequest(
            request: Request<NoBody, Network.NetworkAPI.Endpoint>(
                endpoint: Network.NetworkAPI.Endpoint.info,
                destination: .server(
                    method: .get,
                    server: Network.NetworkAPI.networkAPIServer,
                    queryParameters: [:],
                    x25519PublicKey: Network.NetworkAPI.networkAPIServerPublicKey
                )
            ),
            responseType: Info.self,
            requestAndPathBuildTimeout: Network.defaultTimeout,
            using: dependencies
        )
        .signed(db, with: SessionNetworkAPI.signRequest, using: dependencies)
    }
    
    // MARK: - Authentication
    
    fileprivate static func signatureHeaders(
        _ db: Database,
        url: URL,
        method: HTTPMethod,
        body: Data?,
        using dependencies: Dependencies
    ) throws -> [HTTPHeader: String] {
        let timestamp: UInt64 = UInt64(floor(dependencies.dateNow.timeIntervalSince1970))
        let path: String = url.path
            .appending(url.query.map { value in "?\(value)" })
        
        let signResult: (publicKey: String, signature: [UInt8]) = try sign(
            db,
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
        _ db: Database,
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
            let userEdKeyPair: KeyPair = Identity.fetchUserEd25519KeyPair(db),
            let blinded07KeyPair: KeyPair = dependencies[singleton: .crypto].generate(
                .versionBlinded07KeyPair(ed25519SecretKey: userEdKeyPair.secretKey)
            ),
            let signatureResult: [UInt8] = dependencies[singleton: .crypto].generate(
                .signatureVersionBlind07(
                    timestamp: timestamp,
                    method: method,
                    path: path,
                    body: bodyString,
                    ed25519SecretKey: userEdKeyPair.secretKey
                )
            )
        else { throw NetworkError.signingFailed }
        
        return (
            publicKey: SessionId(.versionBlinded07, publicKey: blinded07KeyPair.publicKey).hexString,
            signature: signatureResult
        )
    }
    
    private static func signRequest<R>(
        _ db: Database,
        preparedRequest: Network.PreparedRequest<R>,
        using dependencies: Dependencies
    ) throws -> Network.Destination {
        guard let url: URL = preparedRequest.destination.url else {
            throw NetworkError.signingFailed
        }
        
        guard case let .server(info) = preparedRequest.destination else {
            throw NetworkError.signingFailed
        }
        
        return .server(
            info: info.updated(
                with: try signatureHeaders(
                    db,
                    url: url,
                    method: preparedRequest.method,
                    body: preparedRequest.body,
                    using: dependencies
                )
            )
        )
    }
}

