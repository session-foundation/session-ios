// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine

import Quick
import Nimble

@testable import SessionUtilitiesKit

private extension HTTPHeader {
    static let testHeader: HTTPHeader = "TestHeader"
}

class PreparedRequestSpec: QuickSpec {
    enum TestEndpoint: EndpointType {
        case endpoint
        
        static var batchRequestVariant: HTTP.BatchRequest.Child.Variant { .storageServer }
        static var excludedSubRequestHeaders: [HTTPHeader] { [.testHeader] }
        
        var path: String { return "endpoint" }
    }
    
    struct TestType: Codable, Equatable {
        let stringValue: String
    }
    
    // MARK: - Spec

    override func spec() {
        describe("a PreparedRequest") {
            var urlRequest: URLRequest?
            var request: Request<NoBody, TestEndpoint>!
            
            // MARK: - when generating a URLRequest
            context("when generating a URLRequest") {
                // MARK: - generates the request correctly
                it("generates the request correctly") {
                    request = Request<NoBody, TestEndpoint>(
                        method: .post,
                        server: "testServer",
                        endpoint: .endpoint,
                        queryParameters: [:],
                        headers: [
                            "TestCustomHeader": "TestCustom",
                            HTTPHeader.testHeader: "Test"
                        ],
                        body: nil
                    )
                    urlRequest = try? request.generateUrlRequest()
                    
                    expect(urlRequest?.url?.absoluteString).to(equal("testServer/endpoint"))
                    expect(urlRequest?.httpMethod).to(equal("POST"))
                    expect(urlRequest?.allHTTPHeaderFields).to(equal([
                        "TestCustomHeader": "TestCustom",
                        HTTPHeader.testHeader: "Test"
                    ]))
                }
                
                it("does not strip excluded subrequest headers") {
                    request = Request<NoBody, TestEndpoint>(
                        method: .post,
                        server: "testServer",
                        endpoint: .endpoint,
                        queryParameters: [:],
                        headers: [
                            "TestCustomHeader": "TestCustom",
                            HTTPHeader.testHeader: "Test"
                        ],
                        body: nil
                    )
                    urlRequest = try? request.generateUrlRequest()
                    
                    expect(TestEndpoint.excludedSubRequestHeaders).to(equal([HTTPHeader.testHeader]))
                    expect(urlRequest?.allHTTPHeaderFields?.keys).to(contain([HTTPHeader.testHeader]))
                }
            }
        }
    }
}
