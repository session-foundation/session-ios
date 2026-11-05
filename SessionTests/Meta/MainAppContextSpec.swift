// Copyright © 2026 Session Technology Foundation. All rights reserved.

import UIKit

import Quick
import Nimble
import SessionUtilitiesKit
import TestUtilities

@testable import Session

class MainAppContextSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration

        let suiteName: String = "MainAppContextSpec"
        let renewalInterval: TimeInterval = 0.05
        @TestState var appGroupDefaults: UserDefaults! = {
            UserDefaults().removePersistentDomain(forName: suiteName)
            return UserDefaults(suiteName: suiteName)
        }()
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.set(defaults: .appGroup, to: appGroupDefaults)
        }
        @TestState var appContext: MainAppContext!

        func post(_ name: Notification.Name) async {
            await MainActor.run { NotificationCenter.default.post(name: name, object: nil) }
        }

        func leaseUntil() -> Date? {
            appGroupDefaults.object(forKey: UserDefaults.DateKey.mainAppActiveUntil.rawValue) as? Date
        }

        afterEach {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

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

            // MARK: -- with the main app lease
            context("with the main app lease") {
                beforeEach {
                    /// The context only reacts to notifications once it exists
                    appContext = MainAppContext(
                        initialApplicationState: .inactive,
                        mainAppLeaseRenewalInterval: renewalInterval,
                        using: dependencies
                    )
                }

                afterEach {
                    /// Stop the renewal timer so it can't write into the next test
                    await post(UIApplication.didEnterBackgroundNotification)
                }

                // MARK: ---- starts the main app lease when becoming active
                it("starts the main app lease when becoming active") {
                    expect(dependencies.isMainAppActive).to(beFalse())

                    await post(UIApplication.didBecomeActiveNotification)

                    expect(dependencies.isMainAppActive).to(beTrue())
                    expect(appContext.reportedApplicationState).to(equal(.active))
                }

                // MARK: ---- keeps the main app lease when resigning active
                it("keeps the main app lease when resigning active") {
                    await post(UIApplication.didBecomeActiveNotification)
                    await post(UIApplication.willResignActiveNotification)

                    expect(dependencies.isMainAppActive).to(beTrue())
                }

                // MARK: ---- ends the main app lease when entering the background
                it("ends the main app lease when entering the background") {
                    await post(UIApplication.didBecomeActiveNotification)
                    await post(UIApplication.didEnterBackgroundNotification)

                    expect(dependencies.isMainAppActive).to(beFalse())
                }

                // MARK: ---- ends the main app lease when terminating
                it("ends the main app lease when terminating") {
                    await post(UIApplication.didBecomeActiveNotification)
                    await post(UIApplication.willTerminateNotification)

                    expect(dependencies.isMainAppActive).to(beFalse())
                }

                // MARK: ---- renews the main app lease while active
                it("renews the main app lease while active") {
                    await post(UIApplication.didBecomeActiveNotification)
                    let initialUntil: Date? = leaseUntil()

                    await expect(leaseUntil()).toEventually(beGreaterThan(initialUntil), timeout: .seconds(1))
                }

                // MARK: ---- stops renewing the main app lease after entering the background
                it("stops renewing the main app lease after entering the background") {
                    await post(UIApplication.didBecomeActiveNotification)
                    await post(UIApplication.didEnterBackgroundNotification)
                    let endedAt: Date? = leaseUntil()
                    try await Task.sleep(for: .milliseconds(Int(renewalInterval * 1000 * 4)))

                    expect(leaseUntil()).to(equal(endedAt))
                }

                // MARK: ---- does not renew the main app lease while the main thread is blocked
                it("does not renew the main app lease while the main thread is blocked") {
                    await post(UIApplication.didBecomeActiveNotification)
                    let initialUntil: Date? = leaseUntil()
                    await expect(leaseUntil()).toEventually(beGreaterThan(initialUntil), timeout: .seconds(1))

                    let (beforeHang, afterHang): (Date?, Date?) = await MainActor.run {
                        let beforeHang: Date? = leaseUntil()
                        Thread.sleep(forTimeInterval: renewalInterval * 6)

                        return (beforeHang, leaseUntil())
                    }

                    expect(afterHang).to(equal(beforeHang))
                    await expect(leaseUntil()).toEventually(beGreaterThan(afterHang), timeout: .seconds(1))
                }
            }
        }
    }
}
