// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import PromiseKit
import SessionSnodeKit
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit
import AVFoundation

class BatchRequestInfoSpec: QuickSpec {
    struct TestType: Codable, Equatable {
        let stringValue: String
    }
    
    // MARK: - Spec

    override func spec() {
        // MARK: - BatchSubRequest
        
        describe("a BatchRequest.Child") {
            var subRequest: OpenGroupAPI.BatchRequest.Child!
            
            context("when initializing") {
                it("sets the headers to nil if there aren't any") {
                    subRequest = OpenGroupAPI.BatchRequest.Child(
                        request: Request<NoBody, OpenGroupAPI.Endpoint>(
                            server: "testServer",
                            endpoint: .batch
                        )
                    )
                    
                    expect(subRequest.headers).to(beNil())
                }
                
                it("converts the headers to HTTP headers") {
                    subRequest = OpenGroupAPI.BatchRequest.Child(
                        request: Request<NoBody, OpenGroupAPI.Endpoint>(
                            method: .get,
                            server: "testServer",
                            endpoint: .batch,
                            queryParameters: [:],
                            headers: [.authorization: "testAuth"],
                            body: nil
                        )
                    )
                    
                    expect(subRequest.headers).to(equal(["Authorization": "testAuth"]))
                }
            }
            
            context("when encoding") {
                it("successfully encodes a string body") {
                    subRequest = OpenGroupAPI.BatchRequest.Child(
                        request: Request<String, OpenGroupAPI.Endpoint>(
                            method: .get,
                            server: "testServer",
                            endpoint: .batch,
                            queryParameters: [:],
                            headers: [:],
                            body: "testBody"
                        )
                    )
                    let subRequestData: Data = try! JSONEncoder().encode(subRequest)
                    let subRequestString: String? = String(data: subRequestData, encoding: .utf8)
                    
                    expect(subRequestString)
                        .to(equal("{\"path\":\"\\/batch\",\"method\":\"GET\",\"b64\":\"testBody\"}"))
                }
                
                it("successfully encodes a byte body") {
                    subRequest = OpenGroupAPI.BatchRequest.Child(
                        request: Request<[UInt8], OpenGroupAPI.Endpoint>(
                            method: .get,
                            server: "testServer",
                            endpoint: .batch,
                            queryParameters: [:],
                            headers: [:],
                            body: [1, 2, 3]
                        )
                    )
                    let subRequestData: Data = try! JSONEncoder().encode(subRequest)
                    let subRequestString: String? = String(data: subRequestData, encoding: .utf8)
                    
                    expect(subRequestString)
                        .to(equal("{\"path\":\"\\/batch\",\"method\":\"GET\",\"bytes\":[1,2,3]}"))
                }
                
                it("successfully encodes a JSON body") {
                    subRequest = OpenGroupAPI.BatchRequest.Child(
                        request: Request<TestType, OpenGroupAPI.Endpoint>(
                            method: .get,
                            server: "testServer",
                            endpoint: .batch,
                            queryParameters: [:],
                            headers: [:],
                            body: TestType(stringValue: "testValue")
                        )
                    )
                    let subRequestData: Data = try! JSONEncoder().encode(subRequest)
                    let subRequestString: String? = String(data: subRequestData, encoding: .utf8)
                    
                    expect(subRequestString)
                        .to(equal("{\"path\":\"\\/batch\",\"method\":\"GET\",\"json\":{\"stringValue\":\"testValue\"}}"))
                }
            }
        }
        
        // MARK: - BatchRequestInfo<T, R>
        
        describe("a BatchRequest.Info") {
            var request: Request<TestType, OpenGroupAPI.Endpoint>!
            
            beforeEach {
                request = Request(
                    method: .get,
                    server: "testServer",
                    endpoint: .batch,
                    queryParameters: [:],
                    headers: [:],
                    body: TestType(stringValue: "testValue")
                )
            }
            
            it("initializes correctly when given a request") {
                let requestInfo: OpenGroupAPI.BatchRequest.Info = OpenGroupAPI.BatchRequest.Info(
                    request: request
                )
                
                expect(requestInfo.endpoint.path).to(equal(request.endpoint.path))
                expect(requestInfo.responseType == HTTP.BatchSubResponse<NoResponse>.self).to(beTrue())
            }
            
            it("initializes correctly when given a request and a response type") {
                let requestInfo: OpenGroupAPI.BatchRequest.Info = OpenGroupAPI.BatchRequest.Info(
                    request: request,
                    responseType: TestType.self
                )
                
                expect(requestInfo.endpoint.path).to(equal(request.endpoint.path))
                expect(requestInfo.responseType == HTTP.BatchSubResponse<TestType>.self).to(beTrue())
            }
            
            it("exposes the endpoint correctly") {
                let requestInfo: OpenGroupAPI.BatchRequest.Info = OpenGroupAPI.BatchRequest.Info(
                    request: request
                )
                
                expect(requestInfo.endpoint.path).to(equal(request.endpoint.path))
            }
            
            it("generates a sub request correctly") {
                let batchRequest: OpenGroupAPI.BatchRequest = OpenGroupAPI.BatchRequest(
                    requests: [
                        OpenGroupAPI.BatchRequest.Info(
                            request: request
                        )
                    ]
                )
                
                expect(batchRequest.requests[0].method).to(equal(request.method))
                expect(batchRequest.requests[0].path).to(equal(request.urlPathAndParamsString))
                expect(batchRequest.requests[0].headers).to(beNil())
            }
        }
    }
}
