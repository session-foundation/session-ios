// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionUtilitiesKit

class BencodeSpec: QuickSpec {
    struct TestType: Codable, Equatable {
        let intValue: Int
        let stringValue: String
    }
    
    // MARK: - Spec

    override func spec() {
        describe("Bencode") {
            context("when decoding") {
                it("should decode a basic string") {
                    let basicStringData: Data = "5:howdy".data(using: .utf8)!
                    let result = try? Bencode.decode(String.self, from: basicStringData)
                    
                    expect(result).to(equal("howdy"))
                }
                
                it("should decode a basic integer") {
                    let basicIntegerData: Data = "i3e".data(using: .utf8)!
                    let result = try? Bencode.decode(Int.self, from: basicIntegerData)
                    
                    expect(result).to(equal(3))
                }
                
                it("should decode a list of integers") {
                    let basicIntListData: Data = "li1ei2ee".data(using: .utf8)!
                    let result = try? Bencode.decode([Int].self, from: basicIntListData)
                    
                    expect(result).to(equal([1, 2]))
                }
                
                it("should decode a basic dict") {
                    let basicDictData: Data = "d4:spaml1:a1:bee".data(using: .utf8)!
                    let result = try? Bencode.decode([String: [String]].self, from: basicDictData)
                    
                    expect(result).to(equal(["spam": ["a", "b"]]))
                }
            }
            
            context("when decoding a response") {
                it("decodes successfully") {
                    let data: Data = "l37:{\"intValue\":100,\"stringValue\":\"Test\"}5:\u{01}\u{02}\u{03}\u{04}\u{05}e"
                        .data(using: .utf8)!
                    let result: BencodeResponse<TestType>? = try? Bencode.decodeResponse(from: data)
                    
                    expect(result)
                        .to(equal(
                            BencodeResponse(
                                info: TestType(
                                    intValue: 100,
                                    stringValue: "Test"
                                ),
                                data: Data([1, 2, 3, 4, 5])
                            )
                        ))
                }
                
                it("decodes successfully with no body") {
                    let data: Data = "l37:{\"intValue\":100,\"stringValue\":\"Test\"}e"
                        .data(using: .utf8)!
                    let result: BencodeResponse<TestType>? = try? Bencode.decodeResponse(from: data)
                    
                    expect(result)
                        .to(equal(
                            BencodeResponse(
                                info: TestType(
                                    intValue: 100,
                                    stringValue: "Test"
                                ),
                                data: nil
                            )
                        ))
                }
                
                it("throws a parsing error when invalid") {
                    let data: Data = "l36:{\"INVALID\":100,\"stringValue\":\"Test\"}5:\u{01}\u{02}\u{03}\u{04}\u{05}e"
                        .data(using: .utf8)!
                    
                    expect {
                        let result: BencodeResponse<TestType> = try Bencode.decodeResponse(from: data)
                        _ = result
                    }.to(throwError(HTTPError.parsingFailed))
                }
            }
        }
    }
}
