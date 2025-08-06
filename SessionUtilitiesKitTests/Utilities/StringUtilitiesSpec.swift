// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionUtilitiesKit

class StringUtilitiesSpec: QuickSpec {
    override class func spec() {
        // MARK: - a String - Truncating
        describe("a String when truncating") {
            // MARK: -- truncates correctly
            it("truncates correctly") {
                let original: String = "12345678900987654321"
                
                expect(original.truncated(prefix: 1, suffix: 1)).to(equal("1...1"))
                expect(original.truncated(prefix: 2, suffix: 2)).to(equal("12...21"))
                expect(original.truncated(prefix: 5, suffix: 3)).to(equal("12345...321"))
            }
            
            // MARK: -- has the correct defaults
            it("has the correct defaults") {
                let original: String = "12345678900987654321"
                
                expect(original.truncated()).to(equal("1234...4321"))
            }
            
            // MARK: -- does not truncate if there aren't enough characters
            it("does not truncate if there aren't enough characters") {
                let original: String = "Test"
                
                expect(original.truncated(prefix: 100, suffix: 100)).to(equal("Test"))
            }
        }
    }
}
