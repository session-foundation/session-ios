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
            
            context("when accessing dateNow") {
                it("creates a new date every time when not overwritten") {
                    let date1 = dependencies.dateNow
                    Thread.sleep(forTimeInterval: 0.05)
                    let date2 = dependencies.dateNow
                    
                    expect(date1.timeIntervalSince1970).toNot(equal(date2.timeIntervalSince1970))
                }
                
                it("returns the same new date every time when overwritten") {
                    dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
                    
                    let date1 = dependencies.dateNow
                    Thread.sleep(forTimeInterval: 0.05)
                    let date2 = dependencies.dateNow
                    
                    expect(date1.timeIntervalSince1970).to(equal(date2.timeIntervalSince1970))
                    expect(date1.timeIntervalSince1970).to(equal(1234567890))
                }
            }
        }
    }
}
