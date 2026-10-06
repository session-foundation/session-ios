// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionNetworkingKit

class RouterSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        @TestState var dependencies: TestDependencies! = TestDependencies()
        
        // MARK: - a Router
        describe("a Router") {
            // MARK: -- does not offer session router
            it("does not offer session router") {
                expect(Router.allCases).to(equal([.onionRequests, .direct]))
            }
            
            // MARK: -- falls back to onion requests when session router was previously stored
            it("falls back to onion requests when session router was previously stored") {
                dependencies.storeFeatureValue(Router.sessionRouter.rawValue, forKey: "router")
                let router: Router = dependencies[feature: .router]
                
                expect(dependencies.rawFeatureValue(forKey: "router") as? Int).to(equal(2))
                expect(router).to(equal(.onionRequests))
            }
            
            // MARK: -- keeps a stored direct selection
            it("keeps a stored direct selection") {
                dependencies.storeFeatureValue(Router.direct.rawValue, forKey: "router")
                let router: Router = dependencies[feature: .router]
                
                expect(router).to(equal(.direct))
            }
        }
    }
}
