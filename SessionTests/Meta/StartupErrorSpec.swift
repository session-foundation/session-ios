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
            // MARK: -- for an error a relaunch can clear
            context("for an error a relaunch can clear") {
                let errors: [(name: String, error: Error)] = [
                    ("databaseSuspended", StorageError.databaseSuspended),
                    ("startupFailed", StorageError.startupFailed),
                    ("CancellationError", CancellationError()),
                    ("SQLITE_BUSY", DatabaseError(resultCode: .SQLITE_BUSY)),
                    ("SQLITE_BUSY_SNAPSHOT", DatabaseError(resultCode: .SQLITE_BUSY_SNAPSHOT)),
                    ("SQLITE_LOCKED", DatabaseError(resultCode: .SQLITE_LOCKED)),
                    ("SQLITE_INTERRUPT", DatabaseError(resultCode: .SQLITE_INTERRUPT)),
                    ("SQLITE_ABORT", DatabaseError(resultCode: .SQLITE_ABORT)),
                    ("SQLITE_CANTOPEN", DatabaseError(resultCode: .SQLITE_CANTOPEN)),
                    ("SQLITE_FULL", DatabaseError(resultCode: .SQLITE_FULL)),
                    ("an unrecognised error", StorageError.generic)
                ]

                // MARK: ---- does not offer to clear the device on the first failure
                it("does not offer to clear the device on the first failure") {
                    errors.forEach { name, error in
                        expect(StartupError.databaseError(error).offersClearDevice(previousFailures: 0))
                            .to(beFalse(), description: name)
                    }
                    expect(StartupError.startupTimeout.offersClearDevice(previousFailures: 0)).to(beFalse())
                }

                // MARK: ---- offers to clear the device when the previous launch also failed
                it("offers to clear the device when the previous launch also failed") {
                    errors.forEach { name, error in
                        expect(StartupError.databaseError(error).offersClearDevice(previousFailures: 1))
                            .to(beTrue(), description: name)
                    }
                    expect(StartupError.startupTimeout.offersClearDevice(previousFailures: 1)).to(beTrue())
                }

                // MARK: ---- tells the user to restart until clearing is offered
                it("tells the user to restart until clearing is offered") {
                    errors.forEach { name, error in
                        expect(StartupError.databaseError(error).message(previousFailures: 0))
                            .to(equal("databaseErrorTimeout".localized()), description: name)
                        expect(StartupError.databaseError(error).message(previousFailures: 1))
                            .to(equal("databaseErrorGeneric".localized()), description: name)
                    }
                }
            }

            // MARK: -- for an error which leaves the database unreadable
            context("for an error which leaves the database unreadable") {
                let errors: [(name: String, error: Error)] = [
                    ("databaseKeyMissingWithActiveDatabase", StorageError.databaseKeyMissingWithActiveDatabase),
                    ("migrationNoLongerSupported", StorageError.migrationNoLongerSupported),
                    ("SQLITE_NOTADB", DatabaseError(resultCode: .SQLITE_NOTADB)),
                    ("SQLITE_CORRUPT", DatabaseError(resultCode: .SQLITE_CORRUPT))
                ]

                // MARK: ---- offers to clear the device on the first failure
                it("offers to clear the device on the first failure") {
                    errors.forEach { name, error in
                        expect(StartupError.databaseError(error).offersClearDevice(previousFailures: 0))
                            .to(beTrue(), description: name)
                    }
                }
            }

            // MARK: -- for a database too old to migrate
            context("for a database too old to migrate") {
                // MARK: ---- tells the user to update
                it("tells the user to update") {
                    expect(StartupError.databaseError(StorageError.migrationNoLongerSupported).message(previousFailures: 0))
                        .to(equal("databaseErrorUpdate".localized()))
                }
            }

            // MARK: -- for a startup timeout
            context("for a startup timeout") {
                // MARK: ---- always tells the user it is taking a long time
                it("always tells the user it is taking a long time") {
                    expect(StartupError.startupTimeout.message(previousFailures: 0))
                        .to(equal("databaseErrorTimeout".localized()))
                    expect(StartupError.startupTimeout.message(previousFailures: 1))
                        .to(equal("databaseErrorTimeout".localized()))
                }
            }
        }
    }
}
