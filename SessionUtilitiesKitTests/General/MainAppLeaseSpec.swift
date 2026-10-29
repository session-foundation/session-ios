// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import TestUtilities

import Quick
import Nimble

@testable import SessionUtilitiesKit

class MainAppLeaseSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration

        let suiteName: String = "MainAppLeaseSpec"
        let now: Date = Date(timeIntervalSince1970: 1_700_000_000)
        @TestState var appGroupDefaults: UserDefaults! = {
            UserDefaults().removePersistentDomain(forName: suiteName)
            return UserDefaults(suiteName: suiteName)
        }()
        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = now
            dependencies.set(defaults: .appGroup, to: appGroupDefaults)
        }

        afterEach {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }

        // MARK: - a MainAppLease
        describe("a MainAppLease") {
            // MARK: -- is inactive when no lease has been written
            it("is inactive when no lease has been written") {
                expect(dependencies.mainAppLease).to(equal(MainAppLease.State.none))
                expect(dependencies.isMainAppActive).to(beFalse())
            }

            // MARK: -- is active after being renewed
            it("is active after being renewed") {
                let until: Date = dependencies.renewMainAppLease()

                expect(until).to(equal(now.addingTimeInterval(MainAppLease.duration)))
                expect(dependencies.mainAppLease).to(equal(.active(until: until, now: now)))
                expect(dependencies.isMainAppActive).to(beTrue())
            }

            // MARK: -- is inactive once ended
            it("is inactive once ended") {
                dependencies.renewMainAppLease()
                dependencies.endMainAppLease()

                expect(dependencies.mainAppLease).to(equal(.expired(at: now, now: now)))
                expect(dependencies.isMainAppActive).to(beFalse())
            }

            // MARK: -- ignores the value of the legacy flag
            it("ignores the value of the legacy flag") {
                appGroupDefaults.set(true, forKey: "isMainAppActive")

                expect(dependencies.isMainAppActive).to(beFalse())
            }

            // MARK: -- when the main app stops renewing it without ending it
            context("when the main app stops renewing it without ending it") {
                beforeEach {
                    dependencies.renewMainAppLease()
                }

                // MARK: ---- remains active until the lease duration has passed
                it("remains active until the lease duration has passed") {
                    dependencies.dateNow = now.addingTimeInterval(MainAppLease.duration - 1)

                    expect(dependencies.isMainAppActive).to(beTrue())
                }

                // MARK: ---- becomes inactive once the lease duration has passed
                it("becomes inactive once the lease duration has passed") {
                    dependencies.dateNow = now.addingTimeInterval(MainAppLease.duration)

                    expect(dependencies.mainAppLease)
                        .to(equal(.expired(at: now.addingTimeInterval(MainAppLease.duration), now: dependencies.dateNow)))
                    expect(dependencies.isMainAppActive).to(beFalse())
                }
            }

            // MARK: -- when the clock has moved backwards since the lease was written
            context("when the clock has moved backwards since the lease was written") {
                // MARK: ---- treats a lease too far in the future as invalid
                it("treats a lease too far in the future as invalid") {
                    let until: Date = now.addingTimeInterval(MainAppLease.duration + MainAppLease.clockSkewAllowance + 1)
                    appGroupDefaults.set(until, forKey: UserDefaults.DateKey.mainAppActiveUntil.rawValue)

                    expect(dependencies.mainAppLease).to(equal(.invalid(until: until, now: now)))
                    expect(dependencies.isMainAppActive).to(beFalse())
                }

                // MARK: ---- still accepts a lease within the allowance
                it("still accepts a lease within the allowance") {
                    let until: Date = now.addingTimeInterval(MainAppLease.duration + MainAppLease.clockSkewAllowance)
                    appGroupDefaults.set(until, forKey: UserDefaults.DateKey.mainAppActiveUntil.rawValue)

                    expect(dependencies.isMainAppActive).to(beTrue())
                }
            }

            // MARK: -- describes itself relative to now
            it("describes itself relative to now") {
                let until: Date = now.addingTimeInterval(45)

                expect(MainAppLease.state(until: until, now: now).description)
                    .to(contain("lease valid until"))
                expect(MainAppLease.state(until: until, now: now).description).to(contain("(+45s)"))
                expect(MainAppLease.state(until: now.addingTimeInterval(-180), now: now).description)
                    .to(contain("lease expired at"))
                expect(MainAppLease.state(until: now.addingTimeInterval(-180), now: now).description)
                    .to(contain("(-180s)"))
                expect(MainAppLease.state(until: nil, now: now).description).to(equal("no lease"))
            }
        }
    }
}
