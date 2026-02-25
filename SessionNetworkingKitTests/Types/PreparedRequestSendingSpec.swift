// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
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
        @TestState var mockNetwork: MockNetwork! = .create(using: dependencies)
        @TestState var preparedRequest: Network.PreparedRequest<Int>!
        @TestState var error: Error?
        
        beforeEach {
            let request: Request<NoBody, TestEndpoint> = Request(
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
            try await mockNetwork.defaultInitialSetup(using: dependencies)
        }
        
        // MARK: - a PreparedRequest sending Onion Requests
        describe("a PreparedRequest sending Onion Requests") {
            // MARK: -- when sending
            context("when sending") {
                beforeEach {
                    try await mockNetwork
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
                        .thenReturn(MockNetwork.response(with: 1))
                }
                
                // MARK: ---- triggers sending correctly
                it("triggers sending correctly") {
                    let response: (info: ResponseInfoType, value: Int) = try await require {
                        try await preparedRequest.send(using: dependencies)
                    }.toNot(throwError())
                    
                    expect(response.value).to(equal(1))
                }

                // MARK: ---- and transforming the result
                context("and transforming the result") {
                    @TestState var receivedOutput: (ResponseInfoType, String)? = nil
                    
                    // MARK: ------ successfully transforms the result
                    it("successfully transforms the result") {
                        receivedOutput = try? await preparedRequest
                            .map { _, output -> String in "\(output)" }
                            .send(using: dependencies)
                        
                        expect(receivedOutput?.1).to(equal("1"))
                    }
                    
                    // MARK: ------ successfully transforms multiple times
                    it("successfully transforms multiple times") {
                        var result: TestType?
                        
                        result = try? await preparedRequest
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
                        
                        expect(result?.intValue).to(equal(1))
                        expect(result?.stringValue).to(equal("Test"))
                        expect(result?.optionalStringValue).to(equal("AnotherString"))
                    }
                    
                    // MARK: ------ will fail if the transformation throws
                    it("will fail if the transformation throws") {
                        await expect {
                            (_, _) = try await preparedRequest
                                .tryMap { _, output -> String in throw NetworkError.invalidState }
                                .send(using: dependencies)
                        }.to(throwError(NetworkError.invalidState))
                    }
                }
                
                // MARK: ---- a batch request
                context("a batch request") {
                    // MARK: ---- with a BatchResponseMap
                    context("with a BatchResponseMap") {
                        @TestState var subRequest1: Request<NoBody, TestEndpoint>! = Request<NoBody, TestEndpoint>(
                            endpoint: TestEndpoint.endpoint1,
                            destination: .server(
                                method: .post,
                                server: "testServer",
                                x25519PublicKey: ""
                            )
                        )
                        @TestState var subRequest2: Request<NoBody, TestEndpoint>! = Request<NoBody, TestEndpoint>(
                            endpoint: TestEndpoint.endpoint2,
                            destination: .server(
                                method: .post,
                                server: "testServer",
                                x25519PublicKey: ""
                            )
                        )
                        @TestState var preparedBatchRequest: Network.PreparedRequest<Network.BatchResponseMap<TestEndpoint>>! = {
                            let request = Request<Network.BatchRequest, TestEndpoint>(
                                endpoint: TestEndpoint.batch,
                                destination: .server(
                                    method: .post,
                                    server: "testServer",
                                    x25519PublicKey: ""
                                ),
                                body: Network.BatchRequest(
                                    target: .sogs,
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
                        @TestState var response: (info: ResponseInfoType, value: Network.BatchResponseMap<TestEndpoint>)?
                        @TestState var receivedOutput: (ResponseInfoType, String)? = nil
                        
                        beforeEach {
                            try await mockNetwork
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
                                .thenReturn(
                                    MockNetwork.batchResponseData(with: [
                                        (endpoint: TestEndpoint.endpoint1, data: TestType.mockBatchSubResponse()),
                                        (endpoint: TestEndpoint.endpoint2, data: TestType.mockBatchSubResponse())
                                    ])
                                )
                        }
                        
                        // MARK: ---- triggers sending correctly
                        it("triggers sending correctly") {
                            response = try await require {
                                try await preparedBatchRequest.send(using: dependencies)
                            }.toNot(throwError())
                            
                            expect(response?.value.count).to(equal(2))
                            expect((response?.value.data[.endpoint1] as? Network.BatchSubResponse<TestType>)?.body)
                                .to(equal(TestType(intValue: 100, stringValue: "Test", optionalStringValue: nil)))
                            expect((response?.value.data[.endpoint2] as? Network.BatchSubResponse<TestType>)?.body)
                                .to(equal(TestType(intValue: 100, stringValue: "Test", optionalStringValue: nil)))
                        }
                        
                        // MARK: ------ works with transformations
                        it("works with transformations") {
                            let receivedOutput: (info: ResponseInfoType, value: String)? = try? await preparedBatchRequest
                                .map { _, _ in "Test" }
                                .send(using: dependencies)
                            
                            expect(receivedOutput?.value).to(equal("Test"))
                        }
                        
                        // MARK: ------ supports transformations on subrequests
                        it("supports transformations on subrequests") {
                            preparedBatchRequest = {
                                let request = Request<Network.BatchRequest, TestEndpoint>(
                                    endpoint: TestEndpoint.batch,
                                    destination: .server(
                                        method: .post,
                                        server: "testServer",
                                        x25519PublicKey: ""
                                    ),
                                    body: Network.BatchRequest(
                                        target: .sogs,
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
                            
                            response = try await require {
                                try await preparedBatchRequest.send(using: dependencies)
                            }.toNot(throwError())
                            
                            expect(response).toNot(beNil())
                            expect(response?.value.count).to(equal(2))
                            expect((response?.value.data[.endpoint1] as? Network.BatchSubResponse<String>)?.body)
                                .to(equal("Test"))
                            expect((response?.value.data[.endpoint2] as? Network.BatchSubResponse<TestType>)?.body)
                                .to(equal(TestType(intValue: 100, stringValue: "Test", optionalStringValue: nil)))
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
    public static var any: TestType {
        TestType(intValue: .any, stringValue: .any, optionalStringValue: .any)
    }
    public static var mock: TestType {
        TestType(intValue: 100, stringValue: "Test", optionalStringValue: nil)
    }
    
    let intValue: Int
    let stringValue: String
    let optionalStringValue: String?
}
