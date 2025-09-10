// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit
import TestUtilities

import Quick
import Nimble

@testable import SessionNetworkingKit

class PreparedRequestSendingSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
        }
        @TestState var mockNetwork: MockNetwork! = .create()
        @TestState var preparedRequest: Network.PreparedRequest<Int>!
        @TestState var error: Error?
        @TestState var disposables: [AnyCancellable]! = []
        
        beforeEach {
            let request: Request<NoBody, TestEndpoint> = try Request(
                endpoint: .endpoint1,
                destination: .server(
                    method: .post,
                    server: "testServer",
                    x25519PublicKey: ""
                ),
                body: nil
            )
            preparedRequest = try Network.PreparedRequest(
                request: request,
                responseType: Int.self,
                using: dependencies
            )
            
            dependencies.set(singleton: .network, to: mockNetwork)
        }
        
        // MARK: - a PreparedRequest sending Onion Requests
        describe("a PreparedRequest sending Onion Requests") {
            // MARK: -- when sending
            context("when sending") {
                beforeEach {
                    try await mockNetwork
                        .when {
                            $0.send(
                                endpoint: MockEndpoint.any,
                                destination: .any,
                                body: .any,
                                category: .any,
                                requestTimeout: .any,
                                overallTimeout: .any
                            )
                        }
                        .thenReturn(MockNetwork.response(with: 1))
                }
                
                // MARK: ---- triggers sending correctly
                it("triggers sending correctly") {
                    var response: (info: ResponseInfoType, data: Int)?
                    
                    preparedRequest
                        .send(using: dependencies)
                        .handleEvents(receiveOutput: { result in response = result })
                        .mapError { error.setting(to: $0) }
                        .sinkAndStore(in: &disposables)
                    
                    expect(response).toNot(beNil())
                    expect(response?.data).to(equal(1))
                    expect(error).to(beNil())
                }
                
                // MARK: ------ can return a cached response
                it("can return a cached response") {
                    var response: (info: ResponseInfoType, data: Int)?
                    
                    preparedRequest = try! Network.PreparedRequest<Int>.cached(
                        100,
                        endpoint: TestEndpoint.endpoint1,
                        using: dependencies
                    )
                    
                    preparedRequest
                        .send(using: dependencies)
                        .handleEvents(receiveOutput: { result in response = result })
                        .mapError { error.setting(to: $0) }
                        .sinkAndStore(in: &disposables)
                    
                    expect(response).toNot(beNil())
                    expect(response?.data).to(equal(100))
                    expect(error).to(beNil())
                }
                
                // MARK: ---- and handling events
                context("and handling events") {
                    @TestState var receivedOutput: (ResponseInfoType, Int)? = nil
                    @TestState var receivedCompletion: Subscribers.Completion<Error>? = nil
                    @TestState var multiReceivedOutput: [(ResponseInfoType, Int)]! = []
                    @TestState var multiReceivedCompletion: [Subscribers.Completion<Error>]! = []
                    
                    // MARK: ------ calls receiveOutput correctly
                    it("calls receiveOutput correctly") {
                        preparedRequest
                            .handleEvents(
                                receiveOutput: { info, output in receivedOutput = (info, output) }
                            )
                            .send(using: dependencies)
                            .sinkAndStore(in: &disposables)
                        
                        expect(receivedOutput).toNot(beNil())
                    }
                    
                    // MARK: ------ calls receiveCompletion correctly
                    it("calls receiveCompletion correctly") {
                        preparedRequest
                            .handleEvents(
                                receiveCompletion: { result in receivedCompletion = result }
                            )
                            .send(using: dependencies)
                            .sinkAndStore(in: &disposables)
                        
                        expect(receivedCompletion).toNot(beNil())
                    }
                    
                    // MARK: ------ calls multiple callbacks without issue
                    it("calls multiple callbacks without issue") {
                        preparedRequest
                            .handleEvents(
                                receiveOutput: { info, output in receivedOutput = (info, output) },
                                receiveCompletion: { result in receivedCompletion = result }
                            )
                            .send(using: dependencies)
                            .sinkAndStore(in: &disposables)
                        
                        expect(receivedOutput).toNot(beNil())
                        expect(receivedCompletion).toNot(beNil())
                    }
                    
                    // MARK: ------ supports multiple handleEvents calls
                    it("supports multiple handleEvents calls") {
                        preparedRequest
                            .handleEvents(
                                receiveOutput: { info, output in multiReceivedOutput.append((info, output)) },
                                receiveCompletion: { result in multiReceivedCompletion.append(result) }
                            )
                            .handleEvents(
                                receiveOutput: { info, output in multiReceivedOutput.append((info, output)) },
                                receiveCompletion: { result in multiReceivedCompletion.append(result) }
                            )
                            .handleEvents(
                                receiveOutput: { info, output in multiReceivedOutput.append((info, output)) },
                                receiveCompletion: { result in multiReceivedCompletion.append(result) }
                            )
                            .send(using: dependencies)
                            .sinkAndStore(in: &disposables)
                        
                        expect(multiReceivedOutput.count).to(equal(3))
                        expect(multiReceivedCompletion.count).to(equal(3))
                    }
                }

                // MARK: ---- and transforming the result
                context("and transforming the result") {
                    @TestState var receivedOutput: (ResponseInfoType, String)? = nil
                    @TestState var didReceiveSubscription: Bool! = false
                    @TestState var receivedCompletion: Subscribers.Completion<Error>? = nil
                    
                    // MARK: ------ successfully transforms the result
                    it("successfully transforms the result") {
                        preparedRequest
                            .map { _, output -> String in "\(output)" }
                            .send(using: dependencies)
                            .handleEvents(receiveOutput: { info, output in receivedOutput = (info, output) })
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(receivedOutput?.1).to(equal("1"))
                    }
                    
                    // MARK: ------ successfully transforms multiple times
                    it("successfully transforms multiple times") {
                        var result: TestType?
                        
                        preparedRequest
                            .map { _, output -> TestType in
                                TestType(intValue: output, stringValue: "Test", optionalStringValue: nil)
                            }
                            .map { _, output -> TestType in
                                TestType(
                                    intValue: output.intValue,
                                    stringValue: output.stringValue,
                                    optionalStringValue: "AnotherString"
                                )
                            }
                            .send(using: dependencies)
                            .handleEvents(receiveOutput: { _, output in result = output })
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(result?.intValue).to(equal(1))
                        expect(result?.stringValue).to(equal("Test"))
                        expect(result?.optionalStringValue).to(equal("AnotherString"))
                    }
                    
                    // MARK: ------ will fail if the transformation throws
                    it("will fail if the transformation throws") {
                        preparedRequest
                            .tryMap { _, output -> String in throw NetworkError.invalidState }
                            .send(using: dependencies)
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(error).to(matchError(NetworkError.invalidState))
                    }
                    
                    // MARK: ------ works with a cached response
                    it("works with a cached response") {
                        var response: (info: ResponseInfoType, data: String)?
                        
                        preparedRequest = try! Network.PreparedRequest<Int>.cached(
                            100,
                            endpoint: TestEndpoint.endpoint1,
                            using: dependencies
                        )
                        
                        preparedRequest
                            .map { _, output -> String in "\(output)" }
                            .send(using: dependencies)
                            .handleEvents(receiveOutput: { result in response = result })
                            .mapError { error.setting(to: $0) }
                            .sinkAndStore(in: &disposables)
                        
                        expect(response).toNot(beNil())
                        expect(response?.data).to(equal("100"))
                        expect(error).to(beNil())
                    }
                    
                    // MARK: ------ works with the event handling
                    it("works with the event handling") {
                        preparedRequest
                            .map { _, output -> String in "\(output)" }
                            .handleEvents(
                                receiveCompletion: { result in receivedCompletion = result }
                            )
                            .send(using: dependencies)
                            .sinkAndStore(in: &disposables)
                        
                        expect(receivedCompletion).toNot(beNil())
                    }
                }
                
                // MARK: ---- a batch request
                context("a batch request") {
                    // MARK: ---- with a BatchResponseMap
                    context("with a BatchResponseMap") {
                        @TestState var subRequest1: Request<NoBody, TestEndpoint>! = try! Request<NoBody, TestEndpoint>(
                            endpoint: TestEndpoint.endpoint1,
                            destination: .server(
                                method: .post,
                                server: "testServer",
                                x25519PublicKey: ""
                            )
                        )
                        @TestState var subRequest2: Request<NoBody, TestEndpoint>! = try! Request<NoBody, TestEndpoint>(
                            endpoint: TestEndpoint.endpoint2,
                            destination: .server(
                                method: .post,
                                server: "testServer",
                                x25519PublicKey: ""
                            )
                        )
                        @TestState var preparedBatchRequest: Network.PreparedRequest<Network.BatchResponseMap<TestEndpoint>>! = {
                            let request = try! Request<Network.BatchRequest, TestEndpoint>(
                                endpoint: TestEndpoint.batch,
                                destination: .server(
                                    method: .post,
                                    server: "testServer",
                                    x25519PublicKey: ""
                                ),
                                body: Network.BatchRequest(
                                    requests: [
                                        try! Network.PreparedRequest(
                                            request: subRequest1,
                                            responseType: TestType.self,
                                            using: dependencies
                                        ),
                                        try! Network.PreparedRequest(
                                            request: subRequest2,
                                            responseType: TestType.self,
                                            using: dependencies
                                        )
                                    ]
                                )
                            )
                            
                            return try! Network.PreparedRequest(
                                request: request,
                                responseType: Network.BatchResponseMap<TestEndpoint>.self,
                                using: dependencies
                            )
                        }()
                        @TestState var response: (info: ResponseInfoType, data: Network.BatchResponseMap<TestEndpoint>)?
                        @TestState var receivedOutput: (ResponseInfoType, String)? = nil
                        @TestState var didReceiveSubscription: Bool! = false
                        @TestState var receivedCompletion: Subscribers.Completion<Error>? = nil
                        
                        beforeEach {
                            try await mockNetwork
                                .when {
                                    $0.send(
                                        endpoint: MockEndpoint.any,
                                        destination: .any,
                                        body: .any,
                                        category: .any,
                                        requestTimeout: .any,
                                        overallTimeout: .any
                                    )
                                }
                                .thenReturn(
                                    MockNetwork.batchResponseData(with: [
                                        (endpoint: TestEndpoint.endpoint1, data: TestType.mockBatchSubResponse()),
                                        (endpoint: TestEndpoint.endpoint2, data: TestType.mockBatchSubResponse())
                                    ])
                                )
                        }
                        
                        // MARK: ---- triggers sending correctly
                        it("triggers sending correctly") {
                            preparedBatchRequest
                                .send(using: dependencies)
                                .handleEvents(receiveOutput: { result in response = result })
                                .mapError { error.setting(to: $0) }
                                .sinkAndStore(in: &disposables)
                            
                            expect(response).toNot(beNil())
                            expect(response?.data.count).to(equal(2))
                            expect((response?.data.data[.endpoint1] as? Network.BatchSubResponse<TestType>)?.body)
                                .to(equal(TestType(intValue: 100, stringValue: "Test", optionalStringValue: nil)))
                            expect((response?.data.data[.endpoint2] as? Network.BatchSubResponse<TestType>)?.body)
                                .to(equal(TestType(intValue: 100, stringValue: "Test", optionalStringValue: nil)))
                            expect(error).to(beNil())
                        }
                        
                        // MARK: ------ works with transformations
                        it("works with transformations") {
                            preparedBatchRequest
                                .map { info, _ in receivedOutput = (info, "Test") }
                                .send(using: dependencies)
                                .sinkAndStore(in: &disposables)
                            
                            expect(receivedOutput?.1).to(equal("Test"))
                        }
                        
                        // MARK: ------ supports transformations on subrequests
                        it("supports transformations on subrequests") {
                            preparedBatchRequest = {
                                let request = try! Request<Network.BatchRequest, TestEndpoint>(
                                    endpoint: TestEndpoint.batch,
                                    destination: .server(
                                        method: .post,
                                        server: "testServer",
                                        x25519PublicKey: ""
                                    ),
                                    body: Network.BatchRequest(
                                        requests: [
                                            try! Network.PreparedRequest(
                                                request: subRequest1,
                                                responseType: TestType.self,
                                                using: dependencies
                                            )
                                            .map { _, _ in "Test" },
                                            try! Network.PreparedRequest(
                                                request: subRequest2,
                                                responseType: TestType.self,
                                                using: dependencies
                                            )
                                        ]
                                    )
                                )
                                
                                return try! Network.PreparedRequest(
                                    request: request,
                                    responseType: Network.BatchResponseMap<TestEndpoint>.self,
                                    using: dependencies
                                )
                            }()
                            
                            preparedBatchRequest
                                .send(using: dependencies)
                                .handleEvents(receiveOutput: { result in response = result })
                                .mapError { error.setting(to: $0) }
                                .sinkAndStore(in: &disposables)
                            
                            expect(response).toNot(beNil())
                            expect(response?.data.count).to(equal(2))
                            expect((response?.data.data[.endpoint1] as? Network.BatchSubResponse<String>)?.body)
                                .to(equal("Test"))
                            expect((response?.data.data[.endpoint2] as? Network.BatchSubResponse<TestType>)?.body)
                                .to(equal(TestType(intValue: 100, stringValue: "Test", optionalStringValue: nil)))
                            expect(error).to(beNil())
                        }
                        
                        // MARK: ------ works with the event handling
                        it("works with the event handling") {
                            preparedBatchRequest
                                .handleEvents(
                                    receiveCompletion: { result in receivedCompletion = result }
                                )
                                .send(using: dependencies)
                                .sinkAndStore(in: &disposables)
                            
                            expect(receivedCompletion).toNot(beNil())
                        }
                        
                        // MARK: ------ supports event handling on sub requests
                        it("supports event handling on sub requests") {
                            preparedBatchRequest = {
                                let request = try! Request<Network.BatchRequest, TestEndpoint>(
                                    endpoint: TestEndpoint.batch,
                                    destination: .server(
                                        method: .post,
                                        server: "testServer",
                                        x25519PublicKey: ""
                                    ),
                                    body: Network.BatchRequest(
                                        requests: [
                                            try! Network.PreparedRequest(
                                                request: subRequest1,
                                                responseType: TestType.self,
                                                using: dependencies
                                            )
                                            .handleEvents(
                                                receiveCompletion: { result in receivedCompletion = result }
                                            ),
                                            try! Network.PreparedRequest(
                                                request: subRequest2,
                                                responseType: TestType.self,
                                                using: dependencies
                                            )
                                        ]
                                    )
                                )
                                
                                return try! Network.PreparedRequest(
                                    request: request,
                                    responseType: Network.BatchResponseMap<TestEndpoint>.self,
                                    using: dependencies
                                )
                            }()
                            
                            preparedBatchRequest
                                .send(using: dependencies)
                                .sinkAndStore(in: &disposables)
                            
                            expect(receivedCompletion).toNot(beNil())
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Test Types

fileprivate enum TestEndpoint: EndpointType {
    case endpoint1
    case endpoint2
    case batch
    
    static var name: String { "TestEndpoint" }
    static var batchRequestVariant: Network.BatchRequest.Child.Variant { .storageServer }
    static var excludedSubRequestHeaders: [HTTPHeader] { [] }
    
    var path: String {
        switch self {
            case .endpoint1: return "endpoint1"
            case .endpoint2: return "endpoint2"
            case .batch: return "batch"
        }
    }
}

fileprivate struct TestType: Codable, Equatable, Mocked {
    public static var any: TestType { TestType(intValue: .any, stringValue: .any, optionalStringValue: .any) }
    public static var mock: TestType { TestType(intValue: 100, stringValue: "Test", optionalStringValue: nil) }
    
    let intValue: Int
    let stringValue: String
    let optionalStringValue: String?
}
