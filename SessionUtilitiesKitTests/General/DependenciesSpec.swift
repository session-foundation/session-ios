// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionUtilitiesKit

class DependenciesSpec: QuickSpec {
    // MARK: - Spec

    override func spec() {
        var dependencies: Dependencies!
        
        describe("Dependencies") {
            beforeEach {
                dependencies = Dependencies()
            }
            
            // These tests seem pointless but we want to make sure we don't modify the logic in
            // such a way that the `dateNow` property gets incorrectly fixed as that will result
            // in the `JobRunner` and `Poller` classes breaking
            context("when accessing dateNow") {
                it("creates a new date every time") {
                    let date1 = dependencies.dateNow
                    Thread.sleep(forTimeInterval: 0.05)
                    let date2 = dependencies.dateNow
                    
                    expect(date1.timeIntervalSince1970).toNot(equal(date2.timeIntervalSince1970))
                }
                
                it("only has read access") {
                    // It looks like when reflecting any computed properties will actually be omitted
                    // so we just need to make sure we don't find a 'dateNow' property
                    let mirror = Mirror(reflecting: dependencies!)
                    let mutableDateNowChild: Mirror.Child? = mirror.children
                        .first { label, _ in label == "dateNow" }
                    
                    expect(mutableDateNowChild).to(beNil())
                }
            }
        }
    }
}
