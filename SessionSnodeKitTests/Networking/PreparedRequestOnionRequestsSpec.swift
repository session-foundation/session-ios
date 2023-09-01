// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionSnodeKit

class PreparedRequestOnionRequestsSpec: QuickSpec {
    enum TestEndpoint: EndpointType {
        case endpoint1
        case endpoint2
        
        static var batchRequestVariant: HTTP.BatchRequest.Child.Variant { .storageServer }
        static var excludedSubRequestHeaders: [HTTPHeader] { [] }
        
        var path: String {
            switch self {
                case .endpoint1: return "endpoint1"
                case .endpoint2: return "endpoint2"
            }
        }
    }
    
    // MARK: - Spec
    
    override func spec() {
        var mockNetwork: MockNetwork!
        var dependencies: TestDependencies!
        var disposables: [AnyCancellable] = []
        
        var error: Error?
        var preparedRequest: HTTP.PreparedRequest<Int>?
        
        describe("a PreparedRequest sending Onion Requests") {
            // MARK: - Configuration
            
            beforeEach {
                mockNetwork = MockNetwork()
                dependencies = TestDependencies(
                    dateNow: Date(timeIntervalSince1970: 1234567890)
                )
                dependencies[singleton: .network] = mockNetwork
                
                let request = Request<NoBody, TestEndpoint>(
                    method: .post,
                    server: "https://www.oxen.io",
                    endpoint: TestEndpoint.endpoint1
                )
                preparedRequest = HTTP.PreparedRequest(
                    request: request,
                    urlRequest: try! request.generateUrlRequest(),
                    publicKey: TestConstants.publicKey,
                    responseType: Int.self,
                    metadata: [:],
                    retryCount: 0,
                    timeout: 10
                )
            }

            afterEach {
                disposables.forEach { $0.cancel() }
                
                mockNetwork = nil
                dependencies = nil
                disposables = []
                
                error = nil
                preparedRequest = nil
            }
            
            // MARK: -- when sending
            context("when sending") {
                beforeEach {
                    mockNetwork
                        .when { $0.send(.onionRequest(any(), to: any(), with: any())) }
                        .thenReturn(MockNetwork.response(with: 1))
                }
                
                // MARK: -- triggers sending correctly
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
                
                // MARK: -- returns an error when the prepared request is null
                it("returns an error when the prepared request is null") {
                    var response: (info: ResponseInfoType, data: Int)?
                    
                    preparedRequest = nil
                    preparedRequest
                        .send(using: dependencies)
                        .handleEvents(receiveOutput: { result in response = result })
                        .mapError { error.setting(to: $0) }
                        .sinkAndStore(in: &disposables)

                    expect(error).to(matchError(HTTPError.invalidPreparedRequest))
                    expect(response).to(beNil())
                }
            }
        }
    }
}
