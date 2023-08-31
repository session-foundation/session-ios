// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine

import Quick
import Nimble

@testable import SessionUtilitiesKit

private extension HTTPHeader {
    static let testHeader: HTTPHeader = "TestHeader"
}

class BatchRequestSpec: QuickSpec {
    enum TestEndpoint1: EndpointType {
        case endpoint1
        
        static var batchRequestVariant: HTTP.BatchRequest.Child.Variant { .sogs }
        static var excludedSubRequestHeaders: [HTTPHeader] { [.testHeader] }
        
        var path: String { return "endpoint1" }
    }
    
    enum TestEndpoint2: EndpointType {
        case endpoint2
        
        static var batchRequestVariant: HTTP.BatchRequest.Child.Variant { .storageServer }
        static var excludedSubRequestHeaders: [HTTPHeader] { [] }
        
        var path: String { return "endpoint2" }
    }
    
    struct TestType: Codable, Equatable {
        let stringValue: String
    }
    
    // MARK: - Spec

    override func spec() {
        describe("a BatchRequest.Child") {
            var request: HTTP.BatchRequest!
            
            // MARK: - when encoding
            context("when encoding") {
                // MARK: -- correctly strips specified headers from sub requests
                it("correctly strips specified headers from sub requests") {
                    let httpRequest: Request<NoBody, TestEndpoint1> = Request<NoBody, TestEndpoint1>(
                        method: .get,
                        server: "testServer",
                        endpoint: .endpoint1,
                        queryParameters: [:],
                        headers: [
                            "TestCustomHeader": "TestCustom",
                            HTTPHeader.testHeader: "Test"
                        ],
                        body: nil
                    )
                    request = HTTP.BatchRequest(
                        requests: [
                            HTTP.PreparedRequest<NoResponse>(
                                request: httpRequest,
                                urlRequest: try! httpRequest.generateUrlRequest(),
                                publicKey: "",
                                responseType: NoResponse.self,
                                timeout: 0
                            )
                        ]
                    )
                    
                    let requestData: Data = try! JSONEncoder().encode(request)
                    let requestString: String? = String(data: requestData, encoding: .utf8)
                    
                    expect(requestString)
                        .toNot(contain([
                            HTTPHeader.testHeader
                        ]))
                }
                
                // MARK: -- does not strip unspecified headers from sub requests
                it("does not strip unspecified headers from sub requests") {
                    let httpRequest: Request<NoBody, TestEndpoint1> = Request<NoBody, TestEndpoint1>(
                        method: .get,
                        server: "testServer",
                        endpoint: .endpoint1,
                        queryParameters: [:],
                        headers: [
                            "TestCustomHeader": "TestCustom",
                            HTTPHeader.testHeader: "Test"
                        ],
                        body: nil
                    )
                    request = HTTP.BatchRequest(
                        requests: [
                            HTTP.PreparedRequest<NoResponse>(
                                request: httpRequest,
                                urlRequest: try! httpRequest.generateUrlRequest(),
                                publicKey: "",
                                responseType: NoResponse.self,
                                timeout: 0
                            )
                        ]
                    )
                    
                    let requestData: Data = try! JSONEncoder().encode(request)
                    let requestString: String? = String(data: requestData, encoding: .utf8)
                    
                    expect(requestString)
                        .to(contain("\"TestCustomHeader\":\"TestCustom\""))
                }
            }
            
            // MARK: - when encoding a sogs type endpoint
            context("when encoding a sogs type endpoint") {
                // MARK: -- successfully encodes a string body
                it("successfully encodes a string body") {
                    request = HTTP.BatchRequest(
                        requests: [
                            HTTP.PreparedRequest<NoResponse>(
                                request: Request<String, TestEndpoint1>(
                                    method: .get,
                                    server: "testServer",
                                    endpoint: .endpoint1,
                                    queryParameters: [:],
                                    headers: [:],
                                    body: "testBody"
                                ),
                                urlRequest: URLRequest(url: URL(string: "https://www.oxen.io")!),
                                publicKey: "",
                                responseType: NoResponse.self,
                                timeout: 0
                            )
                        ]
                    )
                    
                    let requestData: Data? = try? JSONEncoder().encode(request)
                    let requestJson: [[String: Any]]? = requestData
                        .map { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
                    expect(requestJson?.first?["path"] as? String).to(equal("/endpoint1"))
                    expect(requestJson?.first?["method"] as? String).to(equal("GET"))
                    expect(requestJson?.first?["b64"] as? String).to(equal("testBody"))
                }
                
                // MARK: -- successfully encodes a byte body
                it("successfully encodes a byte body") {
                    request = HTTP.BatchRequest(
                        requests: [
                            HTTP.PreparedRequest<NoResponse>(
                                request: Request<[UInt8], TestEndpoint1>(
                                    method: .get,
                                    server: "testServer",
                                    endpoint: .endpoint1,
                                    queryParameters: [:],
                                    headers: [:],
                                    body: [1, 2, 3]
                                ),
                                urlRequest: URLRequest(url: URL(string: "https://www.oxen.io")!),
                                publicKey: "",
                                responseType: NoResponse.self,
                                timeout: 0
                            )
                        ]
                    )
                    
                    let requestData: Data? = try? JSONEncoder().encode(request)
                    let requestJson: [[String: Any]]? = requestData
                        .map { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
                    expect(requestJson?.first?["path"] as? String).to(equal("/endpoint1"))
                    expect(requestJson?.first?["method"] as? String).to(equal("GET"))
                    expect(requestJson?.first?["bytes"] as? [Int]).to(equal([1, 2, 3]))
                }
                
                // MARK: -- successfully encodes a JSON body
                it("successfully encodes a JSON body") {
                    request = HTTP.BatchRequest(
                        requests: [
                            HTTP.PreparedRequest<NoResponse>(
                                request: Request<TestType, TestEndpoint1>(
                                    method: .get,
                                    server: "testServer",
                                    endpoint: .endpoint1,
                                    queryParameters: [:],
                                    headers: [:],
                                    body: TestType(stringValue: "testValue")
                                ),
                                urlRequest: URLRequest(url: URL(string: "https://www.oxen.io")!),
                                publicKey: "",
                                responseType: NoResponse.self,
                                timeout: 0
                            )
                        ]
                    )
                    
                    let requestData: Data? = try? JSONEncoder().encode(request)
                    let requestJson: [[String: Any]]? = requestData
                        .map { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
                    expect(requestJson?.first?["path"] as? String).to(equal("/endpoint1"))
                    expect(requestJson?.first?["method"] as? String).to(equal("GET"))
                    expect(requestJson?.first?["json"] as? [String: String]).to(equal(["stringValue": "testValue"]))
                }
            }
            
            // MARK: - when encoding a storage server type endpoint
            context("when encoding a storage server type endpoint") {
                // MARK: -- successfully encodes a JSON body
                it("successfully encodes a JSON body") {
                    request = HTTP.BatchRequest(
                        requests: [
                            HTTP.PreparedRequest<NoResponse>(
                                request: Request<TestType, TestEndpoint2>(
                                    method: .get,
                                    server: "testServer",
                                    endpoint: .endpoint2,
                                    queryParameters: [:],
                                    headers: [:],
                                    body: TestType(stringValue: "testValue")
                                ),
                                urlRequest: URLRequest(url: URL(string: "https://www.oxen.io")!),
                                publicKey: "",
                                responseType: NoResponse.self,
                                timeout: 0
                            )
                        ]
                    )
                    
                    let requestData: Data? = try? JSONEncoder().encode(request)
                    let requestJson: [[String: Any]]? = requestData
                        .map { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
                    expect(requestJson?.first?["method"] as? String).to(equal("GET"))
                    expect(requestJson?.first?["params"] as? [String: String]).to(equal(["stringValue": "testValue"]))
                }
                
                // MARK: -- ignores a string body
                it("ignores a string body") {
                    request = HTTP.BatchRequest(
                        requests: [
                            HTTP.PreparedRequest<NoResponse>(
                                request: Request<String, TestEndpoint2>(
                                    method: .get,
                                    server: "testServer",
                                    endpoint: .endpoint2,
                                    queryParameters: [:],
                                    headers: [:],
                                    body: "testBody"
                                ),
                                urlRequest: URLRequest(url: URL(string: "https://www.oxen.io")!),
                                publicKey: "",
                                responseType: NoResponse.self,
                                timeout: 0
                            )
                        ]
                    )
                    
                    let requestData: Data? = try? JSONEncoder().encode(request)
                    let requestJson: [[String: Any]]? = requestData
                        .map { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
                    expect(requestJson?.first?["method"] as? String).to(equal("GET"))
                    expect(requestJson?.first?["params"]).to(beNil())
                }
                
                // MARK: -- ignores a byte body
                it("ignores a byte body") {
                    request = HTTP.BatchRequest(
                        requests: [
                            HTTP.PreparedRequest<NoResponse>(
                                request: Request<[UInt8], TestEndpoint2>(
                                    method: .get,
                                    server: "testServer",
                                    endpoint: .endpoint2,
                                    queryParameters: [:],
                                    headers: [:],
                                    body: [1, 2, 3]
                                ),
                                urlRequest: URLRequest(url: URL(string: "https://www.oxen.io")!),
                                publicKey: "",
                                responseType: NoResponse.self,
                                timeout: 0
                            )
                        ]
                    )
                    
                    let requestData: Data? = try? JSONEncoder().encode(request)
                    let requestJson: [[String: Any]]? = requestData
                        .map { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] }
                    expect(requestJson?.first?["method"] as? String).to(equal("GET"))
                    expect(requestJson?.first?["params"]).to(beNil())
                }
            }
        }
    }
}
