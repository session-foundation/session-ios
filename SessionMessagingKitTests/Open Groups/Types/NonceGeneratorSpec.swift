// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionMessagingKit

class NonceGeneratorSpec: QuickSpec {
    override class func spec() {
        // MARK: - a NonceGenerator16Byte
        describe("a NonceGenerator16Byte") {
            // MARK: -- has the correct number of bytes
            it("has the correct number of bytes") {
                expect(OpenGroupAPI.NonceGenerator16Byte().NonceBytes).to(equal(16))
            }
        }
        
        // MARK: - a NonceGenerator24Byte
        describe("a NonceGenerator24Byte") {
            // MARK: -- has the correct number of bytes
            it("has the correct number of bytes") {
                expect(OpenGroupAPI.NonceGenerator24Byte().NonceBytes).to(equal(24))
            }
        }
    }
}
