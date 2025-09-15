// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionNetworkingKit

class PersonalizationSpec: QuickSpec {
    override class func spec() {
        // MARK: - a Personalization
        describe("a Personalization") {
            // MARK: -- generates bytes correctly
            it("generates bytes correctly") {
                expect(Network.SOGS.Personalization.sharedKeys.bytes)
                    .to(equal([115, 111, 103, 115, 46, 115, 104, 97, 114, 101, 100, 95, 107, 101, 121, 115]))
                expect(Network.SOGS.Personalization.authHeader.bytes)
                    .to(equal([115, 111, 103, 115, 46, 97, 117, 116, 104, 95, 104, 101, 97, 100, 101, 114]))
            }
        }
    }
}
