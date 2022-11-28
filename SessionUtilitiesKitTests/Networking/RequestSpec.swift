// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionUtilitiesKit

class RequestSpec: QuickSpec {
    enum TestEndpoint: EndpointType {
        case test1
        case testParams(String, Int)
        
        var path: String {
            switch self {
                case .test1: return "test1"
                case .testParams(let str, let int): return "testParams/\(str)/int/\(int)"
            }
        }
    }
    
    struct TestType: Codable, Equatable {
        let stringValue: String
    }
    
    // MARK: - Spec

    override func spec() {
        describe("a Request") {
            it("is initialized with the correct default values") {
                let request: Request<NoBody, TestEndpoint> = Request(
                    server: "testServer",
                    endpoint: .test1
                )
                
                expect(request.method.rawValue).to(equal("GET"))
                expect(request.queryParameters).to(equal([:]))
                expect(request.headers).to(equal([:]))
                expect(request.body).to(beNil())
            }
            
            context("when generating a URL") {
                it("adds a leading forward slash to the endpoint path") {
                    let request: Request<NoBody, TestEndpoint> = Request(
                        server: "testServer",
                        endpoint: .test1
                    )
                    
                    expect(request.urlPathAndParamsString).to(equal("/test1"))
                }
                
                it("creates a valid URL with no query parameters") {
                    let request: Request<NoBody, TestEndpoint> = Request(
                        server: "testServer",
                        endpoint: .test1
                    )
                    
                    expect(request.urlPathAndParamsString).to(equal("/test1"))
                }
                
                it("creates a valid URL when query parameters are provided") {
                    let request: Request<NoBody, TestEndpoint> = Request(
                        server: "testServer",
                        endpoint: .test1,
                        queryParameters: [
                            .limit: "123"
                        ]
                    )
                    
                    expect(request.urlPathAndParamsString).to(equal("/test1?limit=123"))
                }
            }
            
            context("when generating a URLRequest") {
                it("sets all the values correctly") {
                    let request: Request<NoBody, TestEndpoint> = Request(
                        method: .delete,
                        server: "testServer",
                        endpoint: .test1,
                        headers: [
                            .authorization: "test"
                        ]
                    )
                    let urlRequest: URLRequest? = try? request.generateUrlRequest()
                    
                    expect(urlRequest?.httpMethod).to(equal("DELETE"))
                    expect(urlRequest?.allHTTPHeaderFields).to(equal(["Authorization": "test"]))
                    expect(urlRequest?.httpBody).to(beNil())
                }
                
                it("throws an error if the URL is invalid") {
                    let request: Request<NoBody, TestEndpoint> = Request(
                        server: "testServer",
                        endpoint: .testParams("!!%%", 123)
                    )
                    
                    expect {
                        try request.generateUrlRequest()
                    }
                    .to(throwError(HTTPError.invalidURL))
                }
                
                context("with a base64 string body") {
                    it("successfully encodes the body") {
                        let request: Request<String, TestEndpoint> = Request(
                            server: "testServer",
                            endpoint: .test1,
                            body: "TestMessage".data(using: .utf8)!.base64EncodedString()
                        )
                        
                        let urlRequest: URLRequest? = try? request.generateUrlRequest()
                        let requestBody: Data? = Data(base64Encoded: urlRequest?.httpBody?.base64EncodedString() ?? "")
                        let requestBodyString: String? = String(data: requestBody ?? Data(), encoding: .utf8)
                        
                        expect(requestBodyString).to(equal("TestMessage"))
                    }
                    
                    it("throws an error if the body is not base64 encoded") {
                        let request: Request<String, TestEndpoint> = Request(
                            server: "testServer",
                            endpoint: .test1,
                            body: "TestMessage"
                        )
                        
                        expect {
                            try request.generateUrlRequest()
                        }
                        .to(throwError(HTTPError.parsingFailed))
                    }
                }
                
                context("with a byte body") {
                    it("successfully encodes the body") {
                        let request: Request<[UInt8], TestEndpoint> = Request(
                            server: "testServer",
                            endpoint: .test1,
                            body: [1, 2, 3]
                        )
                        
                        let urlRequest: URLRequest? = try? request.generateUrlRequest()
                        
                        expect(urlRequest?.httpBody?.bytes).to(equal([1, 2, 3]))
                    }
                }
                
                context("with a JSON body") {
                    it("successfully encodes the body") {
                        let request: Request<TestType, TestEndpoint> = Request(
                            server: "testServer",
                            endpoint: .test1,
                            body: TestType(stringValue: "test")
                        )
                        
                        let urlRequest: URLRequest? = try? request.generateUrlRequest()
                        let requestBody: TestType? = try? JSONDecoder().decode(
                            TestType.self,
                            from: urlRequest?.httpBody ?? Data()
                        )
                        
                        expect(requestBody).to(equal(TestType(stringValue: "test")))
                    }
                    
                    it("successfully encodes no body") {
                        let request: Request<NoBody, TestEndpoint> = Request(
                            server: "testServer",
                            endpoint: .test1,
                            body: nil
                        )
                        
                        expect {
                            try request.generateUrlRequest()
                        }.toNot(throwError())
                    }
                }
            }
        }
    }
}
