// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionMessagingKit

class CapabilitySpec: QuickSpec {
    override class func spec() {
        // MARK: - a Capability
        describe("a Capability") {
            // MARK: -- when initializing
            context("when initializing") {
                // MARK: ---- succeeeds with a valid case
                it("succeeeds with a valid case") {
                    let capability: Capability.Variant = Capability.Variant(
                        from: "sogs"
                    )
                    
                    expect(capability).to(equal(.sogs))
                }
                
                // MARK: ---- wraps an unknown value in the unsupported case
                it("wraps an unknown value in the unsupported case") {
                    let capability: Capability.Variant = Capability.Variant(
                        from: "test"
                    )
                    
                    expect(capability).to(equal(.unsupported("test")))
                }
            }
            
            // MARK: -- when accessing the rawValue
            context("when accessing the rawValue") {
                // MARK: ---- provides known cases exactly
                it("provides known cases exactly") {
                    expect(Capability.Variant.sogs.rawValue).to(equal("sogs"))
                    expect(Capability.Variant.blind.rawValue).to(equal("blind"))
                }
                
                // MARK: ---- provides the wrapped value for unsupported cases
                it("provides the wrapped value for unsupported cases") {
                    expect(Capability.Variant.unsupported("test").rawValue).to(equal("test"))
                }
            }
            
            // MARK: -- when Decoding
            context("when Decoding") {
                // MARK: ---- decodes known cases exactly
                it("decodes known cases exactly") {
                    expect(
                        try? JSONDecoder().decode(
                            Capability.Variant.self,
                            from: "\"sogs\"".data(using: .utf8)!
                        )
                    )
                    .to(equal(.sogs))
                    expect(
                        try? JSONDecoder().decode(
                            Capability.Variant.self,
                            from: "\"blind\"".data(using: .utf8)!
                        )
                    )
                    .to(equal(.blind))
                }
                
                // MARK: ---- decodes unknown cases into the unsupported case
                it("decodes unknown cases into the unsupported case") {
                    expect(
                        try? JSONDecoder().decode(
                            Capability.Variant.self,
                            from: "\"test\"".data(using: .utf8)!
                        )
                    )
                    .to(equal(.unsupported("test")))
                }
            }
        }
    }
}
