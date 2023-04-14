// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium

import Quick
import Nimble

@testable import SessionMessagingKit

class LibSessionTypeConversionUtilitiesSpec: QuickSpec {
    // MARK: - Spec

    override func spec() {
        // MARK: - String
        
        describe("a String") {
            it("can convert to a cArray") {
                expect("Test123".cArray).to(equal([84, 101, 115, 116, 49, 50, 51]))
            }
            
            it("can contain emoji") {
                let original: String = "Hi 👋"
                let libSessionVal: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar) = original.toLibSession()
                let result: String? = String(libSessionVal: libSessionVal)
                
                expect(result).to(equal(original))
            }
            
            context("when initialised with a pointer and length") {
                it("returns null when given a null pointer") {
                    let test: [CChar] = [84, 101, 115, 116]
                    let result = test.withUnsafeBufferPointer { ptr in
                        String(pointer: nil, length: 5)
                    }
                    
                    expect(result).to(beNil())
                }
                
                it("returns a truncated string when given an incorrect length") {
                    let test: [CChar] = [84, 101, 115, 116]
                    let result = test.withUnsafeBufferPointer { ptr in
                        String(pointer: UnsafeRawPointer(ptr.baseAddress), length: 2)
                    }
                    
                    expect(result).to(equal("Te"))
                }
                
                it("returns a string when valid") {
                    let test: [CChar] = [84, 101, 115, 116]
                    let result = test.withUnsafeBufferPointer { ptr in
                        String(pointer: UnsafeRawPointer(ptr.baseAddress), length: 4)
                    }
                    
                    expect(result).to(equal("Test"))
                }
            }
            
            context("when initialised with a libSession value") {
                it("returns a string when valid and has no fixed length") {
                    let value: (CChar, CChar, CChar, CChar, CChar) = (84, 101, 115, 116, 0)
                    let result = String(libSessionVal: value, fixedLength: .none)
                    
                    expect(result).to(equal("Test"))
                }
                
                it("returns a string when valid and has a fixed length") {
                    let value: (CChar, CChar, CChar, CChar, CChar) = (84, 101, 0, 115, 116)
                    let result = String(libSessionVal: value, fixedLength: 5)
                    
                    expect(result).to(equal("Te\0st"))
                }
                
                it("truncates at the first null termination character when fixed length is none") {
                    let value: (CChar, CChar, CChar, CChar, CChar) = (84, 101, 0, 115, 116)
                    let result = String(libSessionVal: value, fixedLength: .none)
                    
                    expect(result).to(equal("Te"))
                }
                
                it("parses successfully if there is no null termination character and there is no fixed length") {
                    let value: (CChar, CChar, CChar, CChar, CChar) = (84, 101, 115, 116, 84)
                    let result = String(libSessionVal: value, fixedLength: .none)
                    
                    expect(result).to(equal("TestT"))
                }
                
                it("returns an empty string when given a value only containing null termination characters with a fixed length") {
                    let value: (CChar, CChar, CChar, CChar, CChar) = (0, 0, 0, 0, 0)
                    let result = String(libSessionVal: value, fixedLength: 5)
                    
                    expect(result).to(equal(""))
                }
                
                it("defaults the fixed length value to none") {
                    let value: (CChar, CChar, CChar, CChar, CChar) = (84, 101, 0, 0, 0)
                    let result = String(libSessionVal: value)
                    
                    expect(result).to(equal("Te"))
                }
                
                it("returns an empty string when null and not set to return null") {
                    let value: (CChar, CChar, CChar, CChar, CChar) = (0, 0, 0, 0, 0)
                    let result = String(libSessionVal: value, nullIfEmpty: false)
                    
                    expect(result).to(equal(""))
                }
                
                it("returns null when specified and empty") {
                    let value: (CChar, CChar, CChar, CChar, CChar) = (0, 0, 0, 0, 0)
                    let result = String(libSessionVal: value, nullIfEmpty: true)
                    
                    expect(result).to(beNil())
                }
                
                it("defaults the null if empty flag to false") {
                    let value: (CChar, CChar, CChar, CChar, CChar) = (0, 0, 0, 0, 0)
                    let result = String(libSessionVal: value)
                    
                    expect(result).to(equal(""))
                }
            }
            
            context("when converting to a libSession value") {
                it("succeeeds with a valid value") {
                    let result: (CChar, CChar, CChar, CChar, CChar) = "Test".toLibSession()
                    expect(result.0).to(equal(84))
                    expect(result.1).to(equal(101))
                    expect(result.2).to(equal(115))
                    expect(result.3).to(equal(116))
                    expect(result.4).to(equal(0))
                }
                
                it("truncates when too long") {
                    let result: (CChar, CChar, CChar, CChar, CChar) = "TestTest".toLibSession()
                    expect(result.0).to(equal(84))
                    expect(result.1).to(equal(101))
                    expect(result.2).to(equal(115))
                    expect(result.3).to(equal(116))
                    expect(result.4).to(equal(84))
                }
                
                context("when optional") {
                    context("returns empty when null") {
                        let value: String? = nil
                        let result: (CChar, CChar, CChar, CChar, CChar) = value.toLibSession()
                        
                        expect(result.0).to(equal(0))
                        expect(result.1).to(equal(0))
                        expect(result.2).to(equal(0))
                        expect(result.3).to(equal(0))
                        expect(result.4).to(equal(0))
                    }
                    
                    context("returns a libSession value when not null") {
                        let value: String? = "Test"
                        let result: (CChar, CChar, CChar, CChar, CChar) = value.toLibSession()
                        
                        expect(result.0).to(equal(84))
                        expect(result.1).to(equal(101))
                        expect(result.2).to(equal(115))
                        expect(result.3).to(equal(116))
                        expect(result.4).to(equal(0))
                    }
                }
            }
        }
        
        // MARK: - Data
        
        describe("Data") {
            it("can convert to a cArray") {
                expect(Data([1, 2, 3]).cArray).to(equal([1, 2, 3]))
            }
            
            context("when initialised with a libSession value") {
                it("returns truncated data when given the wrong length") {
                    let value: (UInt8, UInt8, UInt8, UInt8, UInt8) = (1, 2, 3, 4, 5)
                    let result = Data(libSessionVal: value, count: 2)
                    
                    expect(result).to(equal(Data([1, 2])))
                }
                
                it("returns data when valid") {
                    let value: (UInt8, UInt8, UInt8, UInt8, UInt8) = (1, 2, 3, 4, 5)
                    let result = Data(libSessionVal: value, count: 5)
                    
                    expect(result).to(equal(Data([1, 2, 3, 4, 5])))
                }
                
                it("returns data when all bytes are zero and nullIfEmpty is false") {
                    let value: (UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0)
                    let result = Data(libSessionVal: value, count: 5, nullIfEmpty: false)
                    
                    expect(result).to(equal(Data([0, 0, 0, 0, 0])))
                }
                
                it("returns null when all bytes are zero and nullIfEmpty is true") {
                    let value: (UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0)
                    let result = Data(libSessionVal: value, count: 5, nullIfEmpty: true)
                    
                    expect(result).to(beNil())
                }
            }
            
            context("when converting to a libSession value") {
                it("succeeeds with a valid value") {
                    let result: (Int8, Int8, Int8, Int8, Int8) = Data([1, 2, 3, 4, 5]).toLibSession()
                    expect(result.0).to(equal(1))
                    expect(result.1).to(equal(2))
                    expect(result.2).to(equal(3))
                    expect(result.3).to(equal(4))
                    expect(result.4).to(equal(5))
                }
                
                it("truncates when too long") {
                    let result: (Int8, Int8, Int8, Int8, Int8) = Data([1, 2, 3, 4, 1, 2, 3, 4]).toLibSession()
                    expect(result.0).to(equal(1))
                    expect(result.1).to(equal(2))
                    expect(result.2).to(equal(3))
                    expect(result.3).to(equal(4))
                    expect(result.4).to(equal(1))
                }
                
                context("fills with empty data when too short") {
                    let value: Data? = Data([1, 2, 3])
                    let result: (Int8, Int8, Int8, Int8, Int8) = value.toLibSession()
                    
                    expect(result.0).to(equal(1))
                    expect(result.1).to(equal(2))
                    expect(result.2).to(equal(3))
                    expect(result.3).to(equal(0))
                    expect(result.4).to(equal(0))
                }
                
                context("when optional") {
                    context("returns null when null") {
                        let value: Data? = nil
                        let result: (Int8, Int8, Int8, Int8, Int8) = value.toLibSession()
                        
                        expect(result.0).to(equal(0))
                        expect(result.1).to(equal(0))
                        expect(result.2).to(equal(0))
                        expect(result.3).to(equal(0))
                        expect(result.4).to(equal(0))
                    }
                    
                    context("returns a libSession value when not null") {
                        let value: Data? = Data([1, 2, 3, 4, 5])
                        let result: (Int8, Int8, Int8, Int8, Int8) = value.toLibSession()
                        
                        expect(result.0).to(equal(1))
                        expect(result.1).to(equal(2))
                        expect(result.2).to(equal(3))
                        expect(result.3).to(equal(4))
                        expect(result.4).to(equal(5))
                    }
                }
            }
        }
        
        // MARK: - Array
        
        describe("an Array") {
            context("when initialised with a 2D C array") {
                it("returns the correct array") {
                    var test: [CChar] = (
                        "Test1".cArray.nullTerminated() +
                        "Test2".cArray.nullTerminated() +
                        "Test3AndExtra".cArray.nullTerminated()
                    )
                    let result = test.withUnsafeMutableBufferPointer { ptr in
                        var mutablePtr = UnsafeMutablePointer(ptr.baseAddress)
                        
                        return [String](pointer: &mutablePtr, count: 3)
                    }
                    
                    expect(result).to(equal(["Test1", "Test2", "Test3AndExtra"]))
                }
                
                it("returns an empty array if given one") {
                    var test = [CChar]()
                    let result = test.withUnsafeMutableBufferPointer { ptr in
                        var mutablePtr = UnsafeMutablePointer(ptr.baseAddress)
                        
                        return [String](pointer: &mutablePtr, count: 0)
                    }

                    expect(result).to(equal([]))
                }

                it("handles empty strings without issues") {
                    var test: [CChar] = (
                        "Test1".cArray.nullTerminated() +
                        "".cArray.nullTerminated() +
                        "Test2".cArray.nullTerminated()
                    )
                    let result = test.withUnsafeMutableBufferPointer { ptr in
                        var mutablePtr = UnsafeMutablePointer(ptr.baseAddress)
                        
                        return [String](pointer: &mutablePtr, count: 3)
                    }

                    expect(result).to(equal(["Test1", "", "Test2"]))
                }
                
                it("returns null when given a null pointer") {
                    expect([String](pointer: nil, count: 5)).to(beNil())
                }
                
                it("returns null when given a null count") {
                    var test: [CChar] = "Test1".cArray.nullTerminated()
                    let result = test.withUnsafeMutableBufferPointer { ptr in
                        var mutablePtr = UnsafeMutablePointer(ptr.baseAddress)
                        
                        return [String](pointer: &mutablePtr, count: nil)
                    }

                    expect(result).to(beNil())
                }
                
                it("returns the default value if given null values") {
                    expect([String](pointer: nil, count: 5, defaultValue: ["Test"]))
                        .to(equal(["Test"]))
                }
            }
            
            context("when adding a null terminated character") {
                it("adds a null termination character when not present") {
                    let value: [CChar] = [1, 2, 3, 4, 5]
                    
                    expect(value.nullTerminated()).to(equal([1, 2, 3, 4, 5, 0]))
                }
                
                it("adds nothing when already present") {
                    let value: [CChar] = [1, 2, 3, 4, 0]
                    
                    expect(value.nullTerminated()).to(equal([1, 2, 3, 4, 0]))
                }
            }
        }
    }
}
