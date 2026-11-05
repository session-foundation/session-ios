// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

import Quick
import Nimble

@testable import Session

class StartupErrorSpec: QuickSpec {
    override class func spec() {
        // MARK: - a StartupError
        describe("a StartupError") {
            // MARK: -- for a database too old to migrate
            context("for a database too old to migrate") {
                // MARK: ---- tells the user to update
                it("tells the user to update") {
                    expect(StartupError.databaseError(StorageError.migrationNoLongerSupported).message)
                        .to(equal("databaseErrorUpdate".localized()))
                }
            }

            // MARK: -- for any other database error
            context("for any other database error") {
                // MARK: ---- tells the user to restart
                it("tells the user to restart") {
                    let errors: [(name: String, error: Error)] = [
                        ("databaseSuspended", StorageError.databaseSuspended),
                        ("startupFailed", StorageError.startupFailed),
                        ("databaseKeyMissingWithActiveDatabase", StorageError.databaseKeyMissingWithActiveDatabase),
                        ("SQLITE_LOCKED", DatabaseError(resultCode: .SQLITE_LOCKED)),
                        ("CancellationError", CancellationError())
                    ]

                    errors.forEach { name, error in
                        expect(StartupError.databaseError(error).message)
                            .to(equal("shareExtensionDatabaseError".localized()), description: name)
                    }
                }
            }

            // MARK: -- for an unresolved onboarding state
            context("for an unresolved onboarding state") {
                // MARK: ---- tells the user to restart
                it("tells the user to restart") {
                    expect(StartupError.unresolvedOnboardingState.message)
                        .to(equal("shareExtensionDatabaseError".localized()))
                }
            }

            // MARK: -- for a startup timeout
            context("for a startup timeout") {
                // MARK: ---- tells the user it is taking a long time
                it("tells the user it is taking a long time") {
                    expect(StartupError.startupTimeout.message).to(equal("databaseErrorTimeout".localized()))
                }
            }
        }
    }
}
