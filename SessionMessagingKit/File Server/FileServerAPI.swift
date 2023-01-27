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
    public static let maxFileSize = (10 * 1024 * 1024) // 10 MB
    
    /// Standard timeout is 10 seconds which is a little too short fir file upload/download with slightly larger files
    public static let fileTimeout: TimeInterval = 30
    
    // MARK: - File Storage
    
    public static func upload(_ file: Data) -> AnyPublisher<FileUploadResponse, Error> {
        let request = Request(
            method: .post,
            server: server,
            endpoint: Endpoint.file,
            headers: [
                .contentDisposition: "attachment",
                .contentType: "application/octet-stream"
            ],
            body: Array(file)
        )

        return send(request, serverPublicKey: serverPublicKey)
            .decoded(as: FileUploadResponse.self)
    }
    
    public static func download(_ fileId: String, useOldServer: Bool) -> AnyPublisher<Data, Error> {
        let serverPublicKey: String = (useOldServer ? oldServerPublicKey : serverPublicKey)
        let request = Request<NoBody, Endpoint>(
            server: (useOldServer ? oldServer : server),
            endpoint: .fileIndividual(fileId: fileId)
        )
        
        return send(request, serverPublicKey: serverPublicKey)
    }

    public static func getVersion(_ platform: String) -> AnyPublisher<String, Error> {
        let request = Request<NoBody, Endpoint>(
            server: server,
            endpoint: .sessionVersion,
            queryParameters: [
                .platform: platform
            ]
        )
        
        return send(request, serverPublicKey: serverPublicKey)
            .decoded(as: VersionResponse.self)
            .map { response in response.version }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Convenience
    
    private static func send<T: Encodable>(
        _ request: Request<T, Endpoint>,
        serverPublicKey: String
    ) -> AnyPublisher<Data, Error> {
        let urlRequest: URLRequest
        
        do {
            urlRequest = try request.generateUrlRequest()
        }
        catch {
            return Fail(error: error)
                .eraseToAnyPublisher()
        }
        
        return OnionRequestAPI.sendOnionRequest(urlRequest, to: request.server, with: serverPublicKey, timeout: FileServerAPI.fileTimeout)
            .subscribe(on: DispatchQueue.global(qos: .userInitiated))
            .flatMap { _, response -> AnyPublisher<Data, Error> in
                guard let response: Data = response else {
                    return Fail(error: HTTPError.parsingFailed)
                        .eraseToAnyPublisher()
                }
                
                return Just(response)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
            .eraseToAnyPublisher()
    }
}
