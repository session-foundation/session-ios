// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import PromiseKit
import SessionSnodeKit
import SessionUtilitiesKit

@testable import SessionMessagingKit

// FIXME: Change 'OnionRequestAPIType' to have instance methods instead of static methods once everything is updated to use 'Dependencies'
class TestOnionRequestAPI: OnionRequestAPIType {
    struct RequestData: Codable {
        let urlString: String?
        let httpMethod: String
        let headers: [String: String]
        let body: Data?
        let destination: OnionRequestAPIDestination
        
        var publicKey: String? {
            switch destination {
                case .snode: return nil
                case .server(_, _, let x25519PublicKey, _, _): return x25519PublicKey
            }
        }
    }
    
    class ResponseInfo: ResponseInfoType {
        let requestData: RequestData
        let code: Int
        let headers: [String: String]
        
        init(requestData: RequestData, code: Int, headers: [String: String]) {
            self.requestData = requestData
            self.code = code
            self.headers = headers
        }
    }
    
    class var mockResponse: Data? { return nil }
    
    static func sendOnionRequest(_ request: URLRequest, to server: String, with x25519PublicKey: String) -> Promise<(ResponseInfoType, Data?)> {
        let responseInfo: ResponseInfo = ResponseInfo(
            requestData: RequestData(
                urlString: request.url?.absoluteString,
                httpMethod: (request.httpMethod ?? "GET"),
                headers: (request.allHTTPHeaderFields ?? [:]),
                body: request.httpBody,
                destination: OnionRequestAPIDestination.server(
                    host: request.url!.host!,
                    target: OnionRequestAPIVersion.v4.rawValue,
                    x25519PublicKey: x25519PublicKey,
                    scheme: request.url!.scheme,
                    port: request.url!.port.map { UInt16($0) }
                )
            ),
            code: 200,
            headers: [:]
        )
        
        return Promise.value((responseInfo, mockResponse))
    }
    
    static func sendOnionRequest(_ payload: Data, to snode: Snode) -> Promise<(ResponseInfoType, Data?)> {
        let responseInfo: ResponseInfo = ResponseInfo(
            requestData: RequestData(
                urlString: "\(snode.address):\(snode.port)/onion_req/v2",
                httpMethod: "POST",
                headers: [:],
                body: payload,
                destination: OnionRequestAPIDestination.snode(snode)
            ),
            code: 200,
            headers: [:]
        )
        
        return Promise.value((responseInfo, mockResponse))
    }
}
