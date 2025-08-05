// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionUtilitiesKit

class TypeConversionUtilitiesSpec: QuickSpec {
    override class func spec() {
        // MARK: - a String
        describe("a String") {
            // MARK: -- can contain emoji
            it("can contain emoji") {
                let original: String = "Hi 👋"
                var test: TestClass = TestClass()
                test.set(\.testString, to: original)
                let result: String? = test.get(\.testString)
                
                expect(result).to(equal(original))
            }
            
            // MARK: -- when initialised with a pointer and length
            context("when initialised with a pointer and length") {
                // MARK: ---- returns null when given a null pointer
                it("returns null when given a null pointer") {
                    let test: [CChar] = [84, 101, 115, 116]
                    let result = test.withUnsafeBufferPointer { ptr in
                        String(pointer: nil, length: 5)
                    }
                    
                    expect(result).to(beNil())
                }
                
                // MARK: ---- returns a truncated string when given an incorrect length
                it("returns a truncated string when given an incorrect length") {
                    let test: [CChar] = [84, 101, 115, 116]
                    let result = test.withUnsafeBufferPointer { ptr in
                        String(pointer: UnsafeRawPointer(ptr.baseAddress), length: 2)
                    }
                    
                    expect(result).to(equal("Te"))
                }
                
                // MARK: ---- returns a string when valid
                it("returns a string when valid") {
                    let test: [CChar] = [84, 101, 115, 116]
                    let result = test.withUnsafeBufferPointer { ptr in
                        String(pointer: UnsafeRawPointer(ptr.baseAddress), length: 4)
                    }
                    
                    expect(result).to(equal("Test"))
                }
            }
            
            // MARK: -- when initialised with a libSession value
            context("when initialised with a libSession value") {
                // MARK: ---- stores a value correctly
                it("stores a value correctly") {
                    var test: TestClass = TestClass()
                    test.set(\.testString, to: "Test")
                    expect(test.testString.0).to(equal(84))
                    expect(test.testString.1).to(equal(101))
                    expect(test.testString.2).to(equal(115))
                    expect(test.testString.3).to(equal(116))
                    expect(test.testString.4).to(equal(0))
                }
                
                // MARK: ---- truncates when too long
                it("truncates when too long") {
                    let chars30: String = "ThisStringIs_30_CharactersLong"
                    let original: String = "\(chars30)\(chars30)\(chars30)"
                    var test: TestClass = TestClass()
                    test.set(\.testString, to: original)
                    
                    let values: [CChar] = [
                        test.testString.0, test.testString.1, test.testString.2, test.testString.3,
                        test.testString.4, test.testString.5, test.testString.6, test.testString.7,
                        test.testString.8, test.testString.9, test.testString.10, test.testString.11,
                        test.testString.12, test.testString.13, test.testString.14, test.testString.15,
                        test.testString.16, test.testString.17, test.testString.18, test.testString.19,
                        test.testString.20, test.testString.21, test.testString.22, test.testString.23,
                        test.testString.24, test.testString.25, test.testString.26, test.testString.27,
                        test.testString.28, test.testString.29, test.testString.30, test.testString.31,
                        test.testString.32, test.testString.33, test.testString.34, test.testString.35,
                        test.testString.36, test.testString.37, test.testString.38, test.testString.39,
                        test.testString.40, test.testString.41, test.testString.42, test.testString.43,
                        test.testString.44, test.testString.45, test.testString.46, test.testString.47,
                        test.testString.48, test.testString.49, test.testString.50, test.testString.51,
                        test.testString.52, test.testString.53, test.testString.54, test.testString.55,
                        test.testString.56, test.testString.57, test.testString.58, test.testString.59,
                        test.testString.60, test.testString.61, test.testString.62, test.testString.63
                    ]
                    let expectedValue: [CChar] = [
                        84, 104, 105, 115, 83, 116, 114, 105, 110, 103, 73, 115, 95, 51, 48, 95,
                        67, 104, 97, 114, 97, 99, 116, 101, 114, 115, 76, 111, 110, 103, 84, 104,
                        105, 115, 83, 116, 114, 105, 110, 103, 73, 115, 95, 51, 48, 95, 67, 104,
                        97, 114, 97, 99, 116, 101, 114, 115, 76, 111, 110, 103, 84, 104, 105, 115
                    ]
                    expect(values).to(equal(expectedValue))
                    expect(test.testString.64).to(equal(0)) // Last character will always be a null termination
                }
                
                // MARK: ------ returns empty when null
                context("returns empty when null") {
                    var test: TestClass = TestClass()
                    test.set(\.testString, to: nil)
                    
                    let values: [CChar] = [
                        test.testString.0, test.testString.1, test.testString.2, test.testString.3,
                        test.testString.4, test.testString.5, test.testString.6, test.testString.7,
                        test.testString.8, test.testString.9, test.testString.10, test.testString.11,
                        test.testString.12, test.testString.13, test.testString.14, test.testString.15,
                        test.testString.16, test.testString.17, test.testString.18, test.testString.19,
                        test.testString.20, test.testString.21, test.testString.22, test.testString.23,
                        test.testString.24, test.testString.25, test.testString.26, test.testString.27,
                        test.testString.28, test.testString.29, test.testString.30, test.testString.31,
                        test.testString.32, test.testString.33, test.testString.34, test.testString.35,
                        test.testString.36, test.testString.37, test.testString.38, test.testString.39,
                        test.testString.40, test.testString.41, test.testString.42, test.testString.43,
                        test.testString.44, test.testString.45, test.testString.46, test.testString.47,
                        test.testString.48, test.testString.49, test.testString.50, test.testString.51,
                        test.testString.52, test.testString.53, test.testString.54, test.testString.55,
                        test.testString.56, test.testString.57, test.testString.58, test.testString.59,
                        test.testString.60, test.testString.61, test.testString.62, test.testString.63,
                        test.testString.64
                    ]
                    
                    expect(Set(values)).to(equal([0])) // All values should be 0
                }
                
                // MARK: ---- retrieves a value correctly
                it("retrieves a value correctly") {
                    var test: TestClass = TestClass()
                    test.set(\.testString, to: "TestT")
                    let result: String? = test.get(\.testString)
                    
                    expect(result).to(equal("TestT"))
                }
                
                // MARK: ---- truncates at the first null termination character
                it("truncates at the first null termination character") {
                    var test: TestClass = TestClass()
                    test.set(\.testString, to: "TestT")
                    test.testString.2 = 0
                    let result: String? = test.get(\.testString)
                    
                    expect(result).to(equal("Te"))
                }
                
                // MARK: ---- returns an empty string getting a non nullable string with only null termination characters
                it("returns an empty string getting a non nullable string with only null termination characters") {
                    var test: TestClass = TestClass()
                    test.set(\.testString, to: "TestT")
                    test.testString.0 = 0
                    test.testString.1 = 0
                    test.testString.2 = 0
                    test.testString.3 = 0
                    test.testString.4 = 0
                    let result: String = test.get(\.testString)
                    
                    expect(result).to(equal(""))
                }
                
                // MARK: ---- returns an empty string when null and not set to return null
                it("returns an empty string when null and not set to return null") {
                    let test: TestClass = TestClass()
                    let result: String? = test.get(\.testString, nullIfEmpty: false)
                    
                    expect(result).to(equal(""))
                }
                
                // MARK: ---- returns null when specified and empty
                it("returns null when specified and empty") {
                    let test: TestClass = TestClass()
                    let result: String? = test.get(\.testString, nullIfEmpty: true)
                    
                    expect(result).to(beNil())
                }
                
                // MARK: ---- defaults the null if empty flag to false
                it("defaults the null if empty flag to false") {
                    let test: TestClass = TestClass()
                    let result: String? = test.get(\.testString)
                    
                    expect(result).to(equal(""))
                }
            }
        }
        
        // MARK: - Data
        describe("Data") {
            // MARK: -- when initialised with a libSession value
            context("when initialised with a libSession value") {
                // MARK: ---- stores a value correctly
                it("stores a value correctly") {
                    var test: TestClass = TestClass()
                    test.set(\.testData, to: Data([1, 2, 3, 4, 5]))
                    expect(test.testData.0).to(equal(1))
                    expect(test.testData.1).to(equal(2))
                    expect(test.testData.2).to(equal(3))
                    expect(test.testData.3).to(equal(4))
                    expect(test.testData.4).to(equal(5))
                    expect(test.testData.5).to(equal(0))
                }
                
                // MARK: ---- truncates when too long
                it("truncates when too long") {
                    let data20: Data = Data([1, 2, 3, 4, 5, 1, 2, 3, 4, 5, 1, 2, 3, 4, 5, 1, 2, 3, 4, 5])
                    let original: Data = (data20 + data20 + data20)
                    var test: TestClass = TestClass()
                    test.set(\.testData, to: original)
                    
                    let values: [UInt8] = [
                        test.testData.0, test.testData.1, test.testData.2, test.testData.3,
                        test.testData.4, test.testData.5, test.testData.6, test.testData.7,
                        test.testData.8, test.testData.9, test.testData.10, test.testData.11,
                        test.testData.12, test.testData.13, test.testData.14, test.testData.15,
                        test.testData.16, test.testData.17, test.testData.18, test.testData.19,
                        test.testData.20, test.testData.21, test.testData.22, test.testData.23,
                        test.testData.24, test.testData.25, test.testData.26, test.testData.27,
                        test.testData.28, test.testData.29, test.testData.30, test.testData.31
                    ]
                    let expectedValue: [UInt8] = [
                        1, 2, 3, 4, 5, 1, 2, 3, 4, 5, 1, 2, 3, 4, 5, 1,
                        2, 3, 4, 5, 1, 2, 3, 4, 5, 1, 2, 3, 4, 5, 1, 2
                    ]
                    expect(values).to(equal(expectedValue))
                }
                
                // MARK: ---- fills with empty data when too short
                it("fills with empty data when too short") {
                    var test: TestClass = TestClass()
                    test.set(\.testData, to: Data([1, 2, 3]))
                    let result: Data = test.get(\.testData)
                    
                    expect(result.count).to(equal(32))
                    expect(result[0]).to(equal(1))
                    expect(result[1]).to(equal(2))
                    expect(result[2]).to(equal(3))
                    expect(result.filter { $0 != 0 }.count).to(equal(3)) // Only the first 3 values are not zero
                }
                
                // MARK: ------ returns empty when null
                context("returns empty when null") {
                    let original: Data? = nil
                    var test: TestClass = TestClass()
                    test.set(\.testData, to: original)
                    
                    let values: [UInt8] = [
                        test.testData.0, test.testData.1, test.testData.2, test.testData.3,
                        test.testData.4, test.testData.5, test.testData.6, test.testData.7,
                        test.testData.8, test.testData.9, test.testData.10, test.testData.11,
                        test.testData.12, test.testData.13, test.testData.14, test.testData.15,
                        test.testData.16, test.testData.17, test.testData.18, test.testData.19,
                        test.testData.20, test.testData.21, test.testData.22, test.testData.23,
                        test.testData.24, test.testData.25, test.testData.26, test.testData.27,
                        test.testData.28, test.testData.29, test.testData.30, test.testData.31
                    ]
                    
                    expect(Set(values)).to(equal([0])) // All values should be 0
                }
                
                // MARK: ---- retrieves a value correctly
                it("retrieves a value correctly") {
                    var test: TestClass = TestClass()
                    test.set(\.testData, to: Data([1, 2, 3, 4, 5]))
                    let result: Data? = test.get(\.testData)
                    
                    expect(result?.prefix(5)).to(equal(Data([1, 2, 3, 4, 5])))
                    expect(Set((result ?? Data()).suffix(from: 5))).to(equal([0]))
                }
                
                // MARK: ---- returns empty data when null and not set to return null
                it("returns empty data when null and not set to return null") {
                    let test: TestClass = TestClass()
                    let result: Data? = test.get(\.testData, nullIfEmpty: false)
                    
                    expect(result).to(equal(Data(repeating: 0, count: 32)))
                }
                
                // MARK: ---- returns null when specified and empty
                it("returns null when specified and empty") {
                    let test: TestClass = TestClass()
                    let result: Data? = test.get(\.testData, nullIfEmpty: true)
                    
                    expect(result).to(beNil())
                }
                
                // MARK: ---- defaults the null if empty flag to false
                it("defaults the null if empty flag to false") {
                    let test: TestClass = TestClass()
                    let result: Data? = test.get(\.testData)
                    
                    expect(result).to(equal(Data(repeating: 0, count: 32)))
                }
            }
        }
        
        // MARK: - an Array
        describe("an Array") {
            // MARK: -- when initialised with a 2D C array
            context("when initialised with a 2D C array") {
                // MARK: ---- returns the correct array
                it("returns the correct array") {
                    let test: [String] = ["Test1", "Test2", "Test3AndExtra"]
                    
                    let result = try! test.withUnsafeCStrArray { ptr in
                        return [String](cStringArray: ptr.baseAddress, count: 3)
                    }
                    expect(result).to(equal(["Test1", "Test2", "Test3AndExtra"]))
                }
                
                // MARK: ---- returns an empty array if given one
                it("returns an empty array if given one") {
                    let test: [String] = []
                    
                    let result = try! test.withUnsafeCStrArray { ptr in
                        return [String](cStringArray: ptr.baseAddress, count: 0)
                    }
                    expect(result).to(equal([]))
                }

                // MARK: ---- handles empty strings without issues
                it("handles empty strings without issues") {
                    let test: [String] = ["Test1", "", "Test2"]
                    
                    let result = try! test.withUnsafeCStrArray { ptr in
                        return [String](cStringArray: ptr.baseAddress, count: 3)
                    }
                    expect(result).to(equal(["Test1", "", "Test2"]))
                }
                
                // MARK: ---- returns null when given a null pointer
                it("returns null when given a null pointer") {
                    expect([String](
                        cStringArray: Optional<UnsafePointer<UnsafePointer<CChar>?>>.none,
                        count: 5)
                    ).to(beNil())
                }
                
                // MARK: ---- returns null when given a null count
                it("returns null when given a null count") {
                    let test: [String] = ["Test1"]
                    
                    let result = try! test.withUnsafeCStrArray { ptr in
                        return [String](cStringArray: ptr.baseAddress, count: nil)
                    }
                    expect(result).to(beNil())
                }
            }
        }
    }
}

private extension TypeConversionUtilitiesSpec {
    struct TestClass {
        var testString: CChar65
        var testData: CUChar32
        
        init() {
            self.testString = (
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0
            )
            self.testData = (
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
            )
        }
        
        init(testString: CChar65, testData: CUChar32) {
            self.testString = testString
            self.testData = testData
        }
    }
}

extension TypeConversionUtilitiesSpec.TestClass: CAccessible & CMutable {}
