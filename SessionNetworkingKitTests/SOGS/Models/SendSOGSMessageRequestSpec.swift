// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionNetworkingKit

class SendSOGSMessageRequestSpec: QuickSpec {
    override class func spec() {
        // MARK: - a SendSOGSMessageRequest
        describe("a SendSOGSMessageRequest") {
            // MARK: -- when initializing
            context("when initializing") {
                // MARK: ---- defaults the optional values to nil
                it("defaults the optional values to nil") {
                    let request: Network.SOGS.SendSOGSMessageRequest = Network.SOGS.SendSOGSMessageRequest(
                        data: "TestData".data(using: .utf8)!,
                        signature: "TestSignature".data(using: .utf8)!
                    )
                    
                    expect(request.whisperTo).to(beNil())
                    expect(request.whisperMods).to(beNil())
                    expect(request.fileIds).to(beNil())
                }
            }
            
            // MARK: -- when encoding
            context("when encoding") {
                // MARK: ---- encodes the data as a base64 string
                it("encodes the data as a base64 string") {
                    let request: Network.SOGS.SendSOGSMessageRequest = Network.SOGS.SendSOGSMessageRequest(
                        data: "TestData".data(using: .utf8)!,
                        signature: "TestSignature".data(using: .utf8)!,
                        whisperTo: nil,
                        whisperMods: nil,
                        fileIds: nil
                    )
                    let requestData: Data = try! JSONEncoder().encode(request)
                    let requestDataString: String = String(data: requestData, encoding: .utf8)!
                    
                    expect(requestDataString).toNot(contain("TestData"))
                    expect(requestDataString).to(contain("VGVzdERhdGE="))
                }
                
                // MARK: ---- encodes the signature as a base64 string
                it("encodes the signature as a base64 string") {
                    let request: Network.SOGS.SendSOGSMessageRequest = Network.SOGS.SendSOGSMessageRequest(
                        data: "TestData".data(using: .utf8)!,
                        signature: "TestSignature".data(using: .utf8)!,
                        whisperTo: nil,
                        whisperMods: nil,
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
