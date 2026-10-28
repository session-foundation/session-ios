// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import Quick
import Nimble

@testable import SessionUIKit

class SNUIKitConfigurationSpec: AsyncSpec {
    override class func spec() {
        // MARK: - SNUIKit
        describe("SNUIKit") {
            // MARK: -- returns a nav bar icon before it has been configured
            it("returns a nav bar icon before it has been configured") {
                /// The startup "restore" flow can show the landing screen without `SNUIKit` ever having been configured
                let previousConfig: SNUIKit.ConfigType? = SNUIKit.config
                SNUIKit.config = nil

                let icon: NavBarSessionIcon = await MainActor.run { SNUIKit.navBarSessionIcon() }
                SNUIKit.config = previousConfig

                expect(icon).toNot(beNil())
            }
        }
    }
}
