// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionSnodeKit
import SessionUtilitiesKit

public enum FileServerAPI {
    
    // MARK: - Settings
    
    public static let oldServer = "http://88.99.175.227"
    public static let oldServerPublicKey = "7cb31905b55cd5580c686911debf672577b3fb0bff81df4ce2d5c4cb3a7aaa69"
    public static let server = "http://filev2.getsession.org"
    public static let serverPublicKey = "da21e1d886c6fbaea313f75298bd64aab03a97ce985b46bb2dad9f2089c8ee59"
    
    /// **Note:** The max file size is 10,000,000 bytes (rather than 10MiB which would be `(10 * 1024 * 1024)`), 10,000,000
    /// exactly will be fine but a single byte more will result in an error
    public static let maxFileSize = 10_000_000
    
    /// Standard timeout is 10 seconds which is a little too short for file upload/download with slightly larger files
    public static let fileDownloadTimeout: TimeInterval = 30
    public static let fileUploadTimeout: TimeInterval = 60
    
    // MARK: - File Storage
    
    public static func upload(
        _ file: Data,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<FileUploadResponse, Error> {
        let request = Request(
            method: .post,
            server: server,
            endpoint: Endpoint.file,
            headers: [
                .contentDisposition: "attachment",
                .contentType: "application/octet-stream"
            ],
            x25519PublicKey: serverPublicKey,
            body: Array(file)
        )

        return send(request, serverPublicKey: serverPublicKey, timeout: FileServerAPI.fileUploadTimeout, using: dependencies)
            .decoded(as: FileUploadResponse.self)
    }
    
    public static func preparedUpload(
        _ file: Data,
        using dependencies: Dependencies = Dependencies()
    ) throws -> HTTP.PreparedRequest<FileUploadResponse> {
        return try prepareRequest(
            request: Request(
                method: .post,
                server: server,
                endpoint: Endpoint.file,
                headers: [
                    .contentDisposition: "attachment",
                    .contentType: "application/octet-stream"
                ],
                x25519PublicKey: serverPublicKey,
                body: Array(file)
            ),
            responseType: FileUploadResponse.self,
            timeout: FileServerAPI.fileUploadTimeout,
            using: dependencies
        )
    }
    
    public static func download(
        _ fileId: String,
        useOldServer: Bool,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<Data, Error> {
        let serverPublicKey: String = (useOldServer ? oldServerPublicKey : serverPublicKey)
        let request = Request<NoBody, Endpoint>(
            server: (useOldServer ? oldServer : server),
            endpoint: .fileIndividual(fileId: fileId),
            x25519PublicKey: serverPublicKey
        )
        
        return send(request, serverPublicKey: serverPublicKey, timeout: FileServerAPI.fileDownloadTimeout, using: dependencies)
    }

    public static func getVersion(
        _ platform: String,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<String, Error> {
        let request = Request<NoBody, Endpoint>(
            server: server,
            endpoint: .sessionVersion,
            queryParameters: [
                .platform: platform
            ],
            x25519PublicKey: serverPublicKey
        )
        
        return send(request, serverPublicKey: serverPublicKey, timeout: HTTP.defaultTimeout, using: dependencies)
            .decoded(as: VersionResponse.self)
            .map { response in response.version }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Convenience
    
    private static func send<T: Encodable>(
        _ request: Request<T, Endpoint>,
        serverPublicKey: String,
        timeout: TimeInterval,
        using dependencies: Dependencies
    ) -> AnyPublisher<Data, Error> {
        let preparedRequest: HTTP.PreparedRequest<Data?>
        
        do {
            preparedRequest = try prepareRequest(
                request: request,
                responseType: Data?.self,
                timeout: timeout,
                using: dependencies
            )
        }
        catch {
            return Fail(error: error)
                .eraseToAnyPublisher()
        }
        
        return preparedRequest.send(using: dependencies)
            .tryMap { _, response -> Data in
                guard let response: Data = response else { throw HTTPError.parsingFailed }
                
                return response
            }
            .eraseToAnyPublisher()
    }
    
    private static func prepareRequest<T: Encodable, R: Decodable>(
        request: Request<T, Endpoint>,
        responseType: R.Type,
        retryCount: Int = 0,
        timeout: TimeInterval,
        using dependencies: Dependencies
    ) throws -> HTTP.PreparedRequest<R> {
        return HTTP.PreparedRequest<R>(
            request: request,
            urlRequest: try request.generateUrlRequest(using: dependencies),
            responseType: responseType,
            retryCount: retryCount,
            timeout: timeout
        )
    }
}
