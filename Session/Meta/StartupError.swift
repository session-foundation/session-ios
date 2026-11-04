// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionUIKit
import SessionUtilitiesKit

internal enum StartupError: Error, CustomStringConvertible {
    case databaseError(Error)
    case startupTimeout
    
    public var description: String {
        switch self {
            case .databaseError(StorageError.startupFailed), .databaseError(DatabaseError.SQLITE_LOCKED), .databaseError(StorageError.databaseSuspended):
                return "Database startup failed"
            case .databaseError(StorageError.migrationNoLongerSupported): return "Unsupported version"
            case .databaseError(StorageError.databaseKeyMissingWithActiveDatabase): return "Database key missing"
            case .databaseError: return "Database error"
            case .startupTimeout: return "Startup timeout"
        }
    }

    func message(previousFailures: Int) -> String {
        switch self {
            case .databaseError(StorageError.migrationNoLongerSupported):
                return "databaseErrorUpdate"
                    .localized()
            
            case .startupTimeout:
                return "databaseErrorTimeout"
                    .localized()
            
            /// Until clearing is offered, restarting is the only thing the user can do, so the message has to say so
            case .databaseError where !offersClearDevice(previousFailures: previousFailures):
                return "databaseErrorTimeout"
                    .localized()
            
            case .databaseError:
                return "databaseErrorGeneric"
                    .localized()
        }
    }
    
    /// Clearing the device deletes the account from it, so it's only offered once a relaunch has been shown not to help: most
    /// startup failures are transient (the database was suspended or the read cancelled because the app went to the background,
    /// an extension held the write lock past the busy timeout, the previous process still held the file, the keychain was locked)
    /// and, to the user, an error from any of those looks the same as a database which is broken
    ///
    /// `previousFailures` counts the launches before this one which failed in the foreground with no successful launch since,
    /// so the option appears on the second failure in a row
    func offersClearDevice(previousFailures: Int) -> Bool {
        switch self {
            case .databaseError(let error) where StartupError.isUnreadable(error): return true
            case .databaseError, .startupTimeout: return (previousFailures > 0)
        }
    }
    
    /// Errors which mean the data on disk can never be read again, so waiting for a relaunch only delays the user getting back
    /// into their account
    private static func isUnreadable(_ error: Error) -> Bool {
        switch error {
            case StorageError.databaseKeyMissingWithActiveDatabase, StorageError.migrationNoLongerSupported: return true
            case DatabaseError.SQLITE_NOTADB, DatabaseError.SQLITE_CORRUPT: return true
            default: return false
        }
    }
}

// MARK: - UserDefaults

// stringlint:disable_contents
public extension UserDefaults.IntKey {
    /// The number of launches in a row which failed to start while in the foreground, reset by a launch which succeeds
    static let consecutiveFailedStartups: UserDefaults.IntKey = "consecutiveFailedStartups"
}
