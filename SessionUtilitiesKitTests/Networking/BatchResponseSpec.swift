// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine

import Quick
import Nimble

@testable import SessionUtilitiesKit

class BatchResponseSpec: QuickSpec {
    struct TestType: Codable, Equatable {
        let stringValue: String
    }
    struct TestType2: Codable, Equatable {
        let intValue: Int
        let stringValue2: String
    }
    
    // MARK: - Spec

    override func spec() {
        // MARK: - HTTP.BatchSubResponse<T>
        
        describe("an HTTP.BatchSubResponse<T>") {
            context("when decoding") {
                it("decodes correctly") {
                    let jsonString: String = """
                    {
                        "code": 200,
                        "headers": {
                            "testKey": "testValue"
                        },
                        "body": {
                            "stringValue": "testValue"
                        }
                    }
                    """
                    let subResponse: HTTP.BatchSubResponse<TestType>? = try? JSONDecoder().decode(
                        HTTP.BatchSubResponse<TestType>.self,
                        from: jsonString.data(using: .utf8)!
                    )
                    
                    expect(subResponse).toNot(beNil())
                    expect(subResponse?.body).toNot(beNil())
                }
                
                it("decodes with invalid body data") {
                    let jsonString: String = """
                    {
                        "code": 200,
                        "headers": {
                            "testKey": "testValue"
                        },
                        "body": "Hello!!!"
                    }
                    """
                    let subResponse: HTTP.BatchSubResponse<TestType>? = try? JSONDecoder().decode(
                        HTTP.BatchSubResponse<TestType>.self,
                        from: jsonString.data(using: .utf8)!
                    )
                    
                    expect(subResponse).toNot(beNil())
                }
                
                it("flags invalid body data as invalid") {
                    let jsonString: String = """
                    {
                        "code": 200,
                        "headers": {
                            "testKey": "testValue"
                        },
                        "body": "Hello!!!"
                    }
                    """
                    let subResponse: HTTP.BatchSubResponse<TestType>? = try? JSONDecoder().decode(
                        HTTP.BatchSubResponse<TestType>.self,
                        from: jsonString.data(using: .utf8)!
                    )
                    
                    expect(subResponse).toNot(beNil())
                    expect(subResponse?.body).to(beNil())
                    expect(subResponse?.failedToParseBody).to(beTrue())
                }
                
                it("does not flag a missing or invalid optional body as invalid") {
                    let jsonString: String = """
                    {
                        "code": 200,
                        "headers": {
                            "testKey": "testValue"
                        }
                    }
                    """
                    let subResponse: HTTP.BatchSubResponse<TestType?>? = try? JSONDecoder().decode(
                        HTTP.BatchSubResponse<TestType?>.self,
                        from: jsonString.data(using: .utf8)!
                    )
                    
                    expect(subResponse).toNot(beNil())
                    expect(subResponse?.body).to(beNil())
                    expect(subResponse?.failedToParseBody).to(beFalse())
                }
                
                it("does not flag a NoResponse body as invalid") {
                    let jsonString: String = """
                    {
                        "code": 200,
                        "headers": {
                            "testKey": "testValue"
                        }
                    }
                    """
                    let subResponse: HTTP.BatchSubResponse<NoResponse>? = try? JSONDecoder().decode(
                        HTTP.BatchSubResponse<NoResponse>.self,
                        from: jsonString.data(using: .utf8)!
                    )
                    
                    expect(subResponse).toNot(beNil())
                    expect(subResponse?.body).to(beNil())
                    expect(subResponse?.failedToParseBody).to(beFalse())
                }
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
        
        // MARK: - --Combine
        
        describe("a (ResponseInfoType, Data?) Publisher") {
            var responseInfo: ResponseInfoType!
            var testType: TestType!
            var testType2: TestType2!
            var data: Data!
            
            beforeEach {
                responseInfo = HTTP.ResponseInfo(code: 200, headers: [:])
                testType = TestType(stringValue: "test1")
                testType2 = TestType2(intValue: 123, stringValue2: "test2")
                data = """
                [\([
                    try! JSONEncoder().with(outputFormatting: .sortedKeys).encode(
                        HTTP.BatchSubResponse(
                            code: 200,
                            headers: [:],
                            body: testType,
                            failedToParseBody: false
                        )
                    ),
                    try! JSONEncoder().with(outputFormatting: .sortedKeys).encode(
                        HTTP.BatchSubResponse(
                            code: 200,
                            headers: [:],
                            body: testType2,
                            failedToParseBody: false
                        )
                    )
                ]
                .map { String(data: $0, encoding: .utf8)! }
                .joined(separator: ","))]
                """.data(using: .utf8)!
            }
            
            it("decodes valid data correctly") {
                var result: HTTP.BatchResponse?
                Just((responseInfo, data))
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
                    .decoded(as: [
                        HTTP.BatchSubResponse<TestType>.self,
                        HTTP.BatchSubResponse<TestType2>.self
                    ])
                    .sinkUntilComplete(
                        receiveValue: { result = $0 }
                    )
        
                expect(result).toNot(beNil())
                expect((result?.responses[0] as? HTTP.BatchSubResponse<TestType>)?.body)
                    .to(equal(testType))
                expect((result?.responses[1] as? HTTP.BatchSubResponse<TestType2>)?.body)
                    .to(equal(testType2))
            }
            
            it("fails if there is no data") {
                var error: Error?
                Just((responseInfo, nil))
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
                    .decoded(as: [])
                    .mapError { error.setting(to: $0) }
                    .sinkUntilComplete()
                
                expect(error).to(matchError(HTTPError.parsingFailed))
            }
            
            it("fails if the data is not JSON") {
                var error: Error?
                Just((responseInfo, Data([1, 2, 3])))
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
                    .decoded(as: [])
                    .mapError { error.setting(to: $0) }
                    .sinkUntilComplete()
                
                expect(error).to(matchError(HTTPError.parsingFailed))
            }
            
            it("fails if the data is not a JSON array") {
                var error: Error?
                Just((responseInfo, "{}".data(using: .utf8)))
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
                    .decoded(as: [])
                    .mapError { error.setting(to: $0) }
                    .sinkUntilComplete()
                
                expect(error).to(matchError(HTTPError.parsingFailed))
            }
            
            it("fails if the JSON array does not have the same number of items as the expected types") {
                var error: Error?
                Just((responseInfo, data))
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
                    .decoded(as: [
                        HTTP.BatchSubResponse<TestType>.self,
                        HTTP.BatchSubResponse<TestType2>.self,
                        HTTP.BatchSubResponse<TestType2>.self
                    ])
                    .mapError { error.setting(to: $0) }
                    .sinkUntilComplete()
                
                expect(error).to(matchError(HTTPError.parsingFailed))
            }
            
            it("fails if one of the JSON array values fails to decode") {
                data = """
                [\([
                    try! JSONEncoder().with(outputFormatting: .sortedKeys).encode(
                        HTTP.BatchSubResponse(
                            code: 200,
                            headers: [:],
                            body: testType,
                            failedToParseBody: false
                        )
                    )
                ]
                .map { String(data: $0, encoding: .utf8)! }
                .joined(separator: ",")),{"test": "test"}]
                """.data(using: .utf8)!
                
                var error: Error?
                Just((responseInfo, data))
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
                    .decoded(as: [
                        HTTP.BatchSubResponse<TestType>.self,
                        HTTP.BatchSubResponse<TestType2>.self
                    ])
                    .mapError { error.setting(to: $0) }
                    .sinkUntilComplete()
                
                expect(error).to(matchError(HTTPError.parsingFailed))
            }
        }
    }
}
