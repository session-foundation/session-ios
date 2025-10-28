// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

@testable import SessionNetworkingKit

// MARK: - MockNetwork

class MockNetwork: Mock<NetworkType>, NetworkType {
    var requestData: RequestData?
    
    func getSwarm(for swarmPublicKey: String) -> AnyPublisher<Set<LibSession.Snode>, Error> {
        return mock(args: [swarmPublicKey])
    }
    
    func getRandomNodes(count: Int) -> AnyPublisher<Set<LibSession.Snode>, Error> {
        return mock(args: [count])
    }
    
    func send<E: EndpointType>(
        endpoint: E,
        destination: Network.Destination,
        body: Data?,
        requestTimeout: TimeInterval,
        requestAndPathBuildTimeout: TimeInterval?
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        requestData = RequestData(
            method: destination.method,
            headers: destination.headers,
            path: endpoint.path,
            queryParameters: destination.queryParameters,
            body: body,
            requestTimeout: requestTimeout,
            requestAndPathBuildTimeout: requestAndPathBuildTimeout
        )
        
        return mock(args: [body, destination, requestTimeout, requestAndPathBuildTimeout])
    }
    
    func checkClientVersion(ed25519SecretKey: [UInt8]) -> AnyPublisher<(ResponseInfoType, Network.FileServer.AppVersionResponse), Error> {
        return mock(args: [ed25519SecretKey])
    }
}

// MARK: - Test Convenience

extension MockNetwork {
    static func response<T: Encodable>(info: MockResponseInfo = .mock, with value: T) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return Just((info, try? JSONEncoder().with(outputFormatting: .sortedKeys).encode(value)))
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
    
    static func response<T: Mocked & Encodable>(info: MockResponseInfo = .mock, type: T.Type) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return response(info: info, with: T.mock)
    }
    
    static func response<T: Mocked & Encodable>(info: MockResponseInfo = .mock, type: Array<T>.Type) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return response(info: info, with: [T.mock])
    }
    
    static func batchResponseData<E: EndpointType>(
        info: MockResponseInfo = .mock,
        with value: [(endpoint: E, data: Data)]
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        let data: Data = "[\(value.map { String(data: $0.data, encoding: .utf8)! }.joined(separator: ","))]"
            .data(using: .utf8)!
        
        return Just((info, data))
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
    
    static func response(info: MockResponseInfo = .mock, data: Data) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return Just((info, data))
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
    
    static func nullResponse(info: MockResponseInfo = .mock) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return Just((info, nil))
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
    
    static func errorResponse() -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        return Fail(error: TestError.mock).eraseToAnyPublisher()
    }
}

// MARK: - MockResponseInfo

struct MockResponseInfo: ResponseInfoType, Mocked {
    static let mock: MockResponseInfo = MockResponseInfo(requestData: .mock, code: 200, headers: [:])
    
    let requestData: RequestData
    let code: Int
    let headers: [String: String]
    
    init(requestData: RequestData, code: Int, headers: [String: String]) {
        self.requestData = requestData
        self.code = code
        self.headers = headers
    }
}

struct RequestData: Codable, Mocked {
    static let mock: RequestData = RequestData(
        method: .get,
        headers: [:],
        path: "/mock",
        queryParameters: [:],
        body: nil,
        requestTimeout: 0,
        requestAndPathBuildTimeout: nil
    )
    
    let method: HTTPMethod
    let headers: [HTTPHeader: String]
    let path: String
    let queryParameters: [HTTPQueryParam: String]
    let body: Data?
    let requestTimeout: TimeInterval
    let requestAndPathBuildTimeout: TimeInterval?
}

// MARK: - Network.BatchSubResponse Encoding Convenience

extension Encodable where Self: Codable {
    func batchSubResponse() -> Data {
        return try! JSONEncoder().with(outputFormatting: .sortedKeys).encode(
            Network.BatchSubResponse(
                code: 200,
                headers: [:],
                body: self,
                failedToParseBody: false
            )
        )
    }
}

extension Mocked where Self: Codable {
    static func mockBatchSubResponse() -> Data { return mock.batchSubResponse() }
}

extension Array where Element: Mocked, Element: Codable {
    static func mockBatchSubResponse() -> Data { return [Element.mock].batchSubResponse() }
}

// MARK: - Endpoint

enum MockEndpoint: EndpointType, Mocked {
    static var mockValue: MockEndpoint = .mock
    
    case mock
    
    static var name: String { "MockEndpoint" }
    static var batchRequestVariant: Network.BatchRequest.Child.Variant { .storageServer }
    static var excludedSubRequestHeaders: [HTTPHeader] { [] }
    
    var path: String { return "mock" }
}
