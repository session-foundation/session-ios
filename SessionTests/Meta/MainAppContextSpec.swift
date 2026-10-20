// Copyright © 2026 Session Technology Foundation. All rights reserved.

import UIKit

import Quick
import Nimble
import SessionUtilitiesKit
import TestUtilities

@testable import Session

class MainAppContextSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration

        @TestState var dependencies: TestDependencies! = TestDependencies()

        // MARK: - a MainAppContext
        describe("a MainAppContext") {
            // MARK: -- when launched into the background
            context("when launched into the background") {
                // MARK: ---- reports being in the background
                it("reports being in the background") {
                    let appContext: MainAppContext = MainAppContext(
                        initialApplicationState: .background,
                        using: dependencies
                    )

                    expect(appContext.isInBackground).to(beTrue())
                    expect(appContext.isAppForegroundAndActive).to(beFalse())
                }
            }

            // MARK: -- when launched into the foreground
            context("when launched into the foreground") {
                // MARK: ---- does not report being in the background
                it("does not report being in the background") {
                    let appContext: MainAppContext = MainAppContext(
                        initialApplicationState: .inactive,
                        using: dependencies
                    )

                    expect(appContext.isInBackground).to(beFalse())
                    expect(appContext.isAppForegroundAndActive).to(beFalse())
                }
            }
        }
    }
}
