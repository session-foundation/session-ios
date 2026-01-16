// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionNetworkingKit

class SOGSErrorSpec: QuickSpec {
    override class func spec() {
        // MARK: - a SOGSError
        describe("a SOGSError") {
            // MARK: -- generates the error description correctly
            it("generates the error description correctly") {
                expect(SOGSError.decryptionFailed.description).to(equal("Couldn't decrypt response."))
                expect(SOGSError.signingFailed.description).to(equal("Couldn't sign message."))
                expect(SOGSError.noPublicKey.description).to(equal("Couldn't find server public key."))
                expect(SOGSError.invalidEmoji.description).to(equal("The emoji is invalid."))
                expect(SOGSError.invalidPoll.description).to(equal("Poller in invalid state."))
            }
        }
    }
}
