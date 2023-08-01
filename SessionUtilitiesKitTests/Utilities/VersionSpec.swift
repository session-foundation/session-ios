// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionUtilitiesKit

class VersionSpec: QuickSpec {
    // MARK: - Spec

    override func spec() {
        describe("a Version") {
            it("can be created from a string") {
                let version: Version = Version.from("1.20.3")
                
                expect(version.major).to(equal(1))
                expect(version.minor).to(equal(20))
                expect(version.patch).to(equal(3))
            }
            
            it("correctly exposes a string value") {
                let version: Version = Version(major: 1, minor: 20, patch: 3)
                
                expect(version.stringValue).to(equal("1.20.3"))
            }
            
            context("when checking equality") {
                it("returns true if the values match") {
                    let version1: Version = Version.from("1.0.0")
                    let version2: Version = Version.from("1.0.0")
                    
                    expect(version1 == version2)
                        .to(beTrue())
                }
                
                it("returns false if the values do not match") {
                    let version1: Version = Version.from("1.0.0")
                    let version2: Version = Version.from("1.0.1")
                    
                    expect(version1 == version2)
                        .to(beFalse())
                }
            }
            
            context("when comparing versions") {
                it("returns correctly for a simple major difference") {
                    let version1: Version = Version.from("1.0.0")
                    let version2: Version = Version.from("2.0.0")
                    
                    expect(version1 < version2).to(beTrue())
                    expect(version2 > version1).to(beTrue())
                }
                
                it("returns correctly for a complex major difference") {
                    let version1a: Version = Version.from("2.90.90")
                    let version2a: Version = Version.from("10.0.0")
                    let version1b: Version = Version.from("0.7.2")
                    let version2b: Version = Version.from("5.0.2")
                    
                    expect(version1a < version2a).to(beTrue())
                    expect(version2a > version1a).to(beTrue())
                    expect(version1b < version2b).to(beTrue())
                    expect(version2b > version1b).to(beTrue())
                }
                
                it("returns correctly for a simple minor difference") {
                    let version1: Version = Version.from("1.0.0")
                    let version2: Version = Version.from("1.1.0")
                    
                    expect(version1 < version2).to(beTrue())
                    expect(version2 > version1).to(beTrue())
                }
                
                it("returns correctly for a complex minor difference") {
                    let version1a: Version = Version.from("90.2.90")
                    let version2a: Version = Version.from("90.10.0")
                    let version1b: Version = Version.from("2.0.7")
                    let version2b: Version = Version.from("2.5.0")
                    
                    expect(version1a < version2a).to(beTrue())
                    expect(version2a > version1a).to(beTrue())
                    expect(version1b < version2b).to(beTrue())
                    expect(version2b > version1b).to(beTrue())
                }
                
                it("returns correctly for a simple patch difference") {
                    let version1: Version = Version.from("1.0.0")
                    let version2: Version = Version.from("1.0.1")
                    
                    expect(version1 < version2).to(beTrue())
                    expect(version2 > version1).to(beTrue())
                }
                
                it("returns correctly for a complex patch difference") {
                    let version1a: Version = Version.from("90.90.2")
                    let version2a: Version = Version.from("90.90.10")
                    let version1b: Version = Version.from("2.5.0")
                    let version2b: Version = Version.from("2.5.7")
                    
                    expect(version1a < version2a).to(beTrue())
                    expect(version2a > version1a).to(beTrue())
                    expect(version1b < version2b).to(beTrue())
                    expect(version2b > version1b).to(beTrue())
                }
            }
        }
    }
}
