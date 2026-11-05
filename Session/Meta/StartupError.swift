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
    
    /// Startup finished without determining whether there is an account, so neither onboarding nor the home screen is safe to show
    case unresolvedOnboardingState
    
    public var description: String {
        switch self {
            case .databaseError(StorageError.startupFailed), .databaseError(DatabaseError.SQLITE_LOCKED), .databaseError(StorageError.databaseSuspended):
                return "Database startup failed"
            case .databaseError(StorageError.migrationNoLongerSupported): return "Unsupported version"
            case .databaseError(StorageError.databaseKeyMissingWithActiveDatabase): return "Database key missing"
            case .databaseError: return "Database error"
            case .startupTimeout: return "Startup timeout"
            case .unresolvedOnboardingState: return "Onboarding state unresolved"
        }
    }
    
    var message: String {
        switch self {
            case .databaseError(StorageError.migrationNoLongerSupported):
                return "databaseErrorUpdate"
                    .localized()

            /// A missing key could be the keychain failing to read rather than the key being gone, and a restart reads it again;
            /// if it really is gone the alert still offers Clear Device, whose confirmation covers the Recovery Password
            ///
            /// **This must not suggest reinstalling.** Deleting the app deletes the database and attachments with it, so a
            /// transient error which a restart would have fixed becomes a lost account for anyone without their Recovery
            /// Password
            case .databaseError, .unresolvedOnboardingState:
                return "shareExtensionDatabaseError"
                    .localized()
            
            case .startupTimeout:
                return "databaseErrorTimeout"
                    .localized()
        }
    }
}
