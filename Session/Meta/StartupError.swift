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
    
    var message: String {
        switch self {
            case .databaseError(StorageError.migrationNoLongerSupported):
                return "databaseErrorUpdate"
                    .localized()

            case .databaseError:
                return "databaseErrorGeneric"
                    .localized()
            
            case .startupTimeout:
                return "databaseErrorTimeout"
                    .localized()
        }
    }
}
