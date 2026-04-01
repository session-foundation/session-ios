// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
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
    
    var isSuspended: Bool { handler.mock() }
    var hardfork: Int { handler.mock() }
    var softfork: Int { handler.mock() }
    var hasRetrievedNetworkTimeOffset: Bool { handler.mock() }
    var networkTimeOffsetMs: Int64 { handler.mock() }
    var networkStatus: AsyncStream<NetworkStatus> { handler.mock() }
    var syncState: NetworkSyncState { handler.mock() }
    
    func getActivePaths() async throws -> [LibSession.Path] {
        return try handler.mockThrowing()
    }
    
    func getSwarm(for swarmPublicKey: String, ignoreStrikeCount: Bool) async throws -> Set<LibSession.Snode> {
        return try handler.mockThrowing(args: [swarmPublicKey, ignoreStrikeCount])
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
    ) async throws -> (info: ResponseInfoType, value: Data?) {
        return try handler.mockThrowing(args: [endpoint, destination, body, category, requestTimeout, overallTimeout])
    }
    
    func upload(
        fileURL: URL,
        fileName: String?,
        stallTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        overallTimeout: TimeInterval?,
        desiredPathIndex: UInt8?
    ) async throws -> FileMetadata {
        return try handler.mockThrowing(args: [fileURL, fileName, stallTimeout, requestTimeout, overallTimeout, desiredPathIndex])
    }
    
    func download(
        downloadUrl: String,
        stallTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        overallTimeout: TimeInterval?,
        partialMinInterval: TimeInterval,
        desiredPathIndex: UInt8?,
        onProgress: ((UInt64, UInt64) -> Void)?
    ) async throws -> (temporaryFilePath: String, metadata: FileMetadata) {
        return try handler.mockThrowing(args: [downloadUrl, stallTimeout, requestTimeout, overallTimeout, partialMinInterval, desiredPathIndex, onProgress])
    }
    
    func generateDownloadUrl(fileId: String) async throws -> String {
        return try handler.mockThrowing(args: [fileId])
    }
    
    func checkClientVersion(ed25519SecretKey: [UInt8]) async throws -> (info: ResponseInfoType, value: Network.FileServer.AppVersionResponse) {
        return try handler.mockThrowing(args: [ed25519SecretKey])
    }
    
    func resetNetworkStatus() async {
        handler.mockNoReturn()
    }
    
    func setNetworkStatus(status: NetworkStatus) async {
        handler.mockNoReturn(args: [status])
    }
    
    func setNetworkInfo(networkTimeOffsetMs: Int64, hardfork: Int, softfork: Int) async {
        handler.mockNoReturn(args: [networkTimeOffsetMs, hardfork, softfork])
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
    
    func shutdown() async {
        handler.mockNoReturn()
    }
}

// MARK: - Test Convenience

extension MockNetwork {
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
    
    static func downloadResponse(
        temporaryFilePath: String = "TestTmpFilePath",
        metadata: FileMetadata = FileMetadata(
            id: "TestFileId",
            size: 1234,
            uploaded: nil,
            expires: nil
        )
    ) -> (temporaryFilePath: String, metadata: FileMetadata) {
        return (temporaryFilePath, metadata)
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
        path: .any,
        queryParameters: .any,
        body: .any,
        category: .standard,
        requestTimeout: .any,
        overallTimeout: .any
    )
    static let mock: RequestData = RequestData(
        method: .get,
        headers: [:],
        path: "/mock",
        queryParameters: [:],
        body: nil,
        category: .standard,
        requestTimeout: 0,
        overallTimeout: nil
    )
    
    let method: HTTPMethod
    let headers: [HTTPHeader: String]
    let path: String
    let queryParameters: [HTTPQueryParam: String]
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

// MARK: - Convenience

extension MockNetwork {
    func removeRequestMocks() async {
        await self.removeMocksFor {
            try await $0.send(
                endpoint: MockEndpoint.any,
                destination: .any,
                body: .any,
                category: .any,
                requestTimeout: .any,
                overallTimeout: .any
            )
        }
    }
    
    func defaultInitialSetup(using dependencies: Dependencies) async throws {
        try await self
            .when { $0.syncState }
            .thenReturn(
                NetworkSyncState(
                    hardfork: 2,
                    softfork: 11,
                    using: dependencies
                )
            )
        try await self.when { await $0.isSuspended }.thenReturn(false)
        try await self.when { await $0.hardfork }.thenReturn(2)
        try await self.when { await $0.softfork }.thenReturn(11)
        try await self.when { await $0.hasRetrievedNetworkTimeOffset }.thenReturn(false)
        try await self.when { await $0.networkTimeOffsetMs }.thenReturn(0)
        try await self.when { $0.networkStatus }.thenReturn(.singleValue(value: .connected))
        try await self
            .when {
                try await $0.send(
                    endpoint: MockEndpoint.any,
                    destination: .any,
                    body: .any,
                    category: .any,
                    requestTimeout: .any,
                    overallTimeout: .any
                )
            }
            .thenThrow(TestError.mock)
        try await self
            .when { $0.syncState }
            .thenReturn(NetworkSyncState(
                hardfork: 2,
                softfork: 11,
                isSuspended: false,
                using: dependencies
            ))
        try await self
            .when { try await $0.getSwarm(for: .any, ignoreStrikeCount: .any) }
            .thenReturn([
                LibSession.Snode(
                    ed25519PubkeyHex: TestConstants.edPublicKey,
                    ip: "1.1.1.1",
                    httpsPort: 10,
                    quicPort: 1,
                    version: "2.11.0",
                    swarmId: 1
                ),
                LibSession.Snode(
                    ed25519PubkeyHex: TestConstants.edPublicKey,
                    ip: "1.1.1.1",
                    httpsPort: 20,
                    quicPort: 2,
                    version: "2.11.0",
                    swarmId: 1
                ),
                LibSession.Snode(
                    ed25519PubkeyHex: TestConstants.edPublicKey,
                    ip: "1.1.1.1",
                    httpsPort: 30,
                    quicPort: 3,
                    version: "2.11.0",
                    swarmId: 1
                )
            ])
        try await self
            .when { try await $0.generateDownloadUrl(fileId: .any) }
            .thenReturn("https://getsession.org/file/1234")
    }
}
