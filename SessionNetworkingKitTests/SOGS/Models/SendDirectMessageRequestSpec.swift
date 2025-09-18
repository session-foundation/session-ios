// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionNetworkingKit

class SendDirectMessageRequestSpec: QuickSpec {
    override class func spec() {
        // MARK: - a SendDirectMessageRequest
        describe("a SendDirectMessageRequest") {
            // MARK: -- when encoding
            context("when encoding") {
                // MARK: ---- encodes the data as a base64 string
                it("encodes the data as a base64 string") {
                    let request: Network.SOGS.SendDirectMessageRequest = Network.SOGS.SendDirectMessageRequest(
                        message: "TestData".data(using: .utf8)!
                    )
                    let requestData: Data = try! JSONEncoder().encode(request)
                    let requestDataString: String = String(data: requestData, encoding: .utf8)!
                    
                    expect(requestDataString).toNot(contain("TestData"))
                    expect(requestDataString).to(contain("VGVzdERhdGE="))
                }
            }
        }
    }
}
