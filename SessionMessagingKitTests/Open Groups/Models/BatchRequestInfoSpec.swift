// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
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
        // MARK: - BatchRequest.Child
        
        describe("a BatchRequest.Child") {
            var request: OpenGroupAPI.BatchRequest!
            
            context("when initializing") {
                it("sets the headers to nil if there aren't any") {
                    request = OpenGroupAPI.BatchRequest(
                        requests: [
                            OpenGroupAPI.BatchRequest.Info(
                                request: Request<NoBody, OpenGroupAPI.Endpoint>(
                                    server: "testServer",
                                    endpoint: .batch
                                )
                            )
                        ]
                    )
                    
                    expect(request.requests.first?.headers).to(beNil())
                }
                
                it("converts the headers to HTTP headers") {
                    request = OpenGroupAPI.BatchRequest(
                        requests: [
                            OpenGroupAPI.BatchRequest.Info(
                                request: Request<NoBody, OpenGroupAPI.Endpoint>(
                                    method: .get,
                                    server: "testServer",
                                    endpoint: .batch,
                                    queryParameters: [:],
                                    headers: [.authorization: "testAuth"],
                                    body: nil
                                )
                            )
                        ]
                    )
                    
                    expect(request.requests.first?.headers).to(equal(["Authorization": "testAuth"]))
                }
            }
            
            context("when encoding") {
                it("successfully encodes a string body") {
                    request = OpenGroupAPI.BatchRequest(
                        requests: [
                            OpenGroupAPI.BatchRequest.Info(
                                request: Request<String, OpenGroupAPI.Endpoint>(
                                    method: .get,
                                    server: "testServer",
                                    endpoint: .batch,
                                    queryParameters: [:],
                                    headers: [:],
                                    body: "testBody"
                                )
                            )
                        ]
                    )
                    let childRequestData: Data = try! JSONEncoder().encode(request.requests[0])
                    let childRequestString: String? = String(data: childRequestData, encoding: .utf8)
                    
                    expect(childRequestString)
                        .to(equal("{\"path\":\"\\/batch\",\"method\":\"GET\",\"b64\":\"testBody\"}"))
                }
                
                it("successfully encodes a byte body") {
                    request = OpenGroupAPI.BatchRequest(
                        requests: [
                            OpenGroupAPI.BatchRequest.Info(
                                request: Request<[UInt8], OpenGroupAPI.Endpoint>(
                                    method: .get,
                                    server: "testServer",
                                    endpoint: .batch,
                                    queryParameters: [:],
                                    headers: [:],
                                    body: [1, 2, 3]
                                )
                            )
                        ]
                    )
                    let childRequestData: Data = try! JSONEncoder().encode(request.requests[0])
                    let childRequestString: String? = String(data: childRequestData, encoding: .utf8)
                    
                    expect(childRequestString)
                        .to(equal("{\"path\":\"\\/batch\",\"method\":\"GET\",\"bytes\":[1,2,3]}"))
                }
                
                it("successfully encodes a JSON body") {
                    request = OpenGroupAPI.BatchRequest(
                        requests: [
                            OpenGroupAPI.BatchRequest.Info(
                                request: Request<TestType, OpenGroupAPI.Endpoint>(
                                    method: .get,
                                    server: "testServer",
                                    endpoint: .batch,
                                    queryParameters: [:],
                                    headers: [:],
                                    body: TestType(stringValue: "testValue")
                                )
                            )
                        ]
                    )
                    let childRequestData: Data = try! JSONEncoder().encode(request.requests[0])
                    let childRequestString: String? = String(data: childRequestData, encoding: .utf8)
                    
                    expect(childRequestString)
                        .to(equal("{\"path\":\"\\/batch\",\"method\":\"GET\",\"json\":{\"stringValue\":\"testValue\"}}"))
                }
            }
        }
        
        // MARK: - BatchRequest.Info
        
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
        }
        
        // MARK: - Convenience
        // MARK: --Decodable
        
        describe("a Decodable") {
            it("decodes correctly") {
                let jsonData: Data = "{\"stringValue\":\"testValue\"}".data(using: .utf8)!
                let result: TestType? = try? TestType.decoded(from: jsonData)
                
                expect(result).to(equal(TestType(stringValue: "testValue")))
            }
        }
    }
}
