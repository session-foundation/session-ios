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
            
            context("when encoding") {
                it("successfully encodes a string body") {
                    request = OpenGroupAPI.BatchRequest(
                        requests: [
                            OpenGroupAPI.PreparedSendData<NoResponse>(
                                request: Request<String, OpenGroupAPI.Endpoint>(
                                    method: .get,
                                    server: "testServer",
                                    endpoint: .batch,
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
                    let requestData: Data = try! JSONEncoder().encode(request)
                    let requestString: String? = String(data: requestData, encoding: .utf8)
                    
                    expect(requestString)
                        .to(equal("[{\"path\":\"\\/batch\",\"method\":\"GET\",\"b64\":\"testBody\"}]"))
                }
                
                it("successfully encodes a byte body") {
                    request = OpenGroupAPI.BatchRequest(
                        requests: [
                            OpenGroupAPI.PreparedSendData<NoResponse>(
                                request: Request<[UInt8], OpenGroupAPI.Endpoint>(
                                    method: .get,
                                    server: "testServer",
                                    endpoint: .batch,
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
                    let requestData: Data = try! JSONEncoder().encode(request)
                    let requestString: String? = String(data: requestData, encoding: .utf8)
                    
                    expect(requestString)
                        .to(equal("[{\"path\":\"\\/batch\",\"method\":\"GET\",\"bytes\":[1,2,3]}]"))
                }
                
                it("successfully encodes a JSON body") {
                    request = OpenGroupAPI.BatchRequest(
                        requests: [
                            OpenGroupAPI.PreparedSendData<NoResponse>(
                                request: Request<TestType, OpenGroupAPI.Endpoint>(
                                    method: .get,
                                    server: "testServer",
                                    endpoint: .batch,
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
                    let requestData: Data = try! JSONEncoder().encode(request)
                    let requestString: String? = String(data: requestData, encoding: .utf8)
                    
                    expect(requestString)
                        .to(equal("[{\"path\":\"\\/batch\",\"method\":\"GET\",\"json\":{\"stringValue\":\"testValue\"}}]"))
                }
                
                it("strips authentication headers") {
                    let httpRequest: Request<NoBody, OpenGroupAPI.Endpoint> = Request<NoBody, OpenGroupAPI.Endpoint>(
                        method: .get,
                        server: "testServer",
                        endpoint: .batch,
                        queryParameters: [:],
                        headers: [
                            "TestHeader": "Test",
                            HTTPHeader.sogsPubKey: "A",
                            HTTPHeader.sogsTimestamp: "B",
                            HTTPHeader.sogsNonce: "C",
                            HTTPHeader.sogsSignature: "D"
                        ],
                        body: nil
                    )
                    request = OpenGroupAPI.BatchRequest(
                        requests: [
                            OpenGroupAPI.PreparedSendData<NoResponse>(
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
                            HTTPHeader.sogsPubKey,
                            HTTPHeader.sogsTimestamp,
                            HTTPHeader.sogsNonce,
                            HTTPHeader.sogsSignature
                        ]))
                }
            }
            
            it("does not strip non authentication headers") {
                let httpRequest: Request<NoBody, OpenGroupAPI.Endpoint> = Request<NoBody, OpenGroupAPI.Endpoint>(
                    method: .get,
                    server: "testServer",
                    endpoint: .batch,
                    queryParameters: [:],
                    headers: [
                        "TestHeader": "Test",
                        HTTPHeader.sogsPubKey: "A",
                        HTTPHeader.sogsTimestamp: "B",
                        HTTPHeader.sogsNonce: "C",
                        HTTPHeader.sogsSignature: "D"
                    ],
                    body: nil
                )
                request = OpenGroupAPI.BatchRequest(
                    requests: [
                        OpenGroupAPI.PreparedSendData<NoResponse>(
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
                    .to(contain("\"TestHeader\":\"Test\""))
            }
        }
    }
}
