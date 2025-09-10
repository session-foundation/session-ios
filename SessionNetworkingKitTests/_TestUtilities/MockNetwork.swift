// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit
import TestUtilities

@testable import SessionNetworkingKit

// MARK: - MockNetwork

class MockNetwork: NetworkType, Mockable {
    public var handler: MockHandler<NetworkType>
    
    required init(handler: MockHandler<NetworkType>) {
        self.handler = handler
    }
    
    required init(handlerForBuilder: any MockFunctionHandler) {
        self.handler = MockHandler(forwardingHandler: handlerForBuilder)
    }
    
    var requestData: RequestData?
    
    var isSuspended: Bool { handler.mock() }
    var networkStatus: AsyncStream<NetworkStatus> { handler.mock() }
    var syncState: NetworkSyncState { handler.mock() }
    
    func getActivePaths() async throws -> [LibSession.Path] {
        return try handler.mockThrowing()
    }
    
    func getSwarm(for swarmPublicKey: String) async throws -> Set<LibSession.Snode> {
        return try handler.mockThrowing(args: [swarmPublicKey])
    }
    
    func getRandomNodes(count: Int) async throws -> Set<LibSession.Snode> {
        return try handler.mockThrowing(args: [count])
    }
    
    func send<E: EndpointType>(
        endpoint: E,
        destination: Network.Destination,
        body: Data?,
        category: Network.RequestCategory,
        requestTimeout: TimeInterval,
        overallTimeout: TimeInterval?
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        requestData = RequestData(
            method: destination.method,
            headers: destination.headers,
            urlPathAndParamsString: destination.urlPathAndParamsString,
            body: body,
            category: category,
            requestTimeout: requestTimeout,
            overallTimeout: overallTimeout
        )
        
        return handler.mock(args: [endpoint, destination, body, category, requestTimeout, overallTimeout])
    }
    
    func send<E: EndpointType>(
        endpoint: E,
        destination: Network.Destination,
        body: Data?,
        category: Network.RequestCategory,
        requestTimeout: TimeInterval,
        overallTimeout: TimeInterval?
    ) async throws -> (info: ResponseInfoType, value: Data?) {
        requestData = RequestData(
            method: destination.method,
            headers: destination.headers,
            urlPathAndParamsString: destination.urlPathAndParamsString,
            body: body,
            category: category,
            requestTimeout: requestTimeout,
            overallTimeout: overallTimeout
        )
        
        return try handler.mockThrowing(args: [endpoint, destination, body, category, requestTimeout, overallTimeout])
    }
    
    func checkClientVersion(ed25519SecretKey: [UInt8]) async throws -> (info: ResponseInfoType, value: AppVersionResponse) {
        return try handler.mockThrowing(args: [ed25519SecretKey])
    }
    
    func resetNetworkStatus() async {
        handler.mockNoReturn()
    }
    
    func setNetworkStatus(status: NetworkStatus) async {
        handler.mockNoReturn(args: [status])
    }
    
    func suspendNetworkAccess() async {
        handler.mockNoReturn()
    }
    
    func resumeNetworkAccess(autoReconnect: Bool) async {
        handler.mockNoReturn(args: [autoReconnect])
    }
    
    func finishCurrentObservations() async {
        handler.mockNoReturn()
    }
    
    func clearCache() async {
        handler.mockNoReturn()
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
    
    static func response<T: Encodable>(info: MockResponseInfo = .mock, with value: T) -> (ResponseInfoType, Data?) {
        return (info, try? JSONEncoder().with(outputFormatting: .sortedKeys).encode(value))
    }
    
    static func response<T: Mocked & Encodable>(info: MockResponseInfo = .mock, type: T.Type) -> (ResponseInfoType, Data?) {
        return response(info: info, with: T.mock)
    }
    
    static func response<T: Mocked & Encodable>(info: MockResponseInfo = .mock, type: Array<T>.Type) -> (ResponseInfoType, Data?) {
        return response(info: info, with: [T.mock])
    }
    
    static func batchResponseData<E: EndpointType>(
        info: MockResponseInfo = .mock,
        with value: [(endpoint: E, data: Data)]
    ) -> (ResponseInfoType, Data?) {
        let data: Data = "[\(value.map { String(data: $0.data, encoding: .utf8)! }.joined(separator: ","))]"
            .data(using: .utf8)!
        
        return (info, data)
    }
    
    static func response(info: MockResponseInfo = .mock, data: Data) -> (ResponseInfoType, Data?) {
        return (info, data)
    }
    
    static func nullResponse(info: MockResponseInfo = .mock) -> (ResponseInfoType, Data?) {
        return (info, nil)
    }
}

// MARK: - MockResponseInfo

struct MockResponseInfo: ResponseInfoType, Mocked {
    static let any: MockResponseInfo = MockResponseInfo(requestData: .any, code: .any, headers: .any)
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
    static let any: RequestData = RequestData(
        method: .get,
        headers: .any,
        urlPathAndParamsString: .any,
        body: .any,
        category: .standard,
        requestTimeout: .any,
        overallTimeout: .any
    )
    static let mock: RequestData = RequestData(
        method: .get,
        headers: [:],
        urlPathAndParamsString: "",
        body: nil,
        category: .standard,
        requestTimeout: 0,
        overallTimeout: nil
    )
    
    let method: HTTPMethod
    let headers: [HTTPHeader: String]
    let urlPathAndParamsString: String
    let body: Data?
    let category: Network.RequestCategory
    let requestTimeout: TimeInterval
    let overallTimeout: TimeInterval?
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

public extension Mocked where Self: Codable {
    static func mockBatchSubResponse() -> Data { return mock.batchSubResponse() }
}

public extension Array where Element: Mocked, Element: Codable {
    static func mockBatchSubResponse() -> Data { return [Element.mock].batchSubResponse() }
}

// MARK: - Endpoint

enum MockEndpoint: EndpointType, Mocked {
    static var any: MockEndpoint = .anyValue
    static var mockValue: MockEndpoint = .mock
    static var skipTypeMatchForAnyComparison: Bool { true }
    
    case anyValue
    case mock
    
    static var name: String { "MockEndpoint" }
    static var batchRequestVariant: Network.BatchRequest.Child.Variant { .storageServer }
    static var excludedSubRequestHeaders: [HTTPHeader] { [] }
    
    var path: String {
        switch self {
            case .anyValue: return "__MOCKED_ANY_ENDPOINT_VALUE__"
            case .mock: return "mock"
        }
    }
}
