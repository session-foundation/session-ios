// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionNetworkingKit

class CapabilitiesResponseSpec: QuickSpec {
    override class func spec() {
        // MARK: - CapabilitiesResponse
        describe("CapabilitiesResponse") {
            // MARK: -- when initializing
            context("when initializing") {
                // MARK: ---- assigns values correctly
                it("assigns values correctly") {
                    let capabilities: Network.SOGS.CapabilitiesResponse = Network.SOGS.CapabilitiesResponse(
                        capabilities: ["sogs"],
                        missing: ["test"]
                    )
                    
                    expect(capabilities.capabilities).to(equal(["sogs"]))
                    expect(capabilities.missing).to(equal(["test"]))
                }
                
                it("defaults missing to nil") {
                    let capabilities: Network.SOGS.CapabilitiesResponse = Network.SOGS.CapabilitiesResponse(
                        capabilities: ["sogs"]
                    )
                    
                    expect(capabilities.capabilities).to(equal(["sogs"]))
                    expect(capabilities.missing).to(beNil())
                }
            }
        }
    }
}
