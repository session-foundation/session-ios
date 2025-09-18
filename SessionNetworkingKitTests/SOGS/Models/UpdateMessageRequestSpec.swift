// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionNetworkingKit

class UpdateMessageRequestSpec: QuickSpec {
    override class func spec() {
        // MARK: - an UpdateMessageRequest
        describe("an UpdateMessageRequest") {
            // MARK: -- when encoding
            context("when encoding") {
                // MARK: ---- encodes the data as a base64 string
                it("encodes the data as a base64 string") {
                    let request: Network.SOGS.UpdateMessageRequest = Network.SOGS.UpdateMessageRequest(
                        data: "TestData".data(using: .utf8)!,
                        signature: "TestSignature".data(using: .utf8)!,
                        fileIds: nil
                    )
                    let requestData: Data = try! JSONEncoder().encode(request)
                    let requestDataString: String = String(data: requestData, encoding: .utf8)!
                    
                    expect(requestDataString).toNot(contain("TestData"))
                    expect(requestDataString).to(contain("VGVzdERhdGE="))
                }
                
                // MARK: ---- encodes the signature as a base64 string
                it("encodes the signature as a base64 string") {
                    let request: Network.SOGS.UpdateMessageRequest = Network.SOGS.UpdateMessageRequest(
                        data: "TestData".data(using: .utf8)!,
                        signature: "TestSignature".data(using: .utf8)!,
                        fileIds: nil
                    )
                    let requestData: Data = try! JSONEncoder().encode(request)
                    let requestDataString: String = String(data: requestData, encoding: .utf8)!
                    
                    expect(requestDataString).toNot(contain("TestSignature"))
                    expect(requestDataString).to(contain("VGVzdFNpZ25hdHVyZQ=="))
                }
            }
        }
    }
}
