// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import GRDB
import SessionUIKit
import SessionUtilitiesKit

internal enum StartupError: Error, CustomStringConvertible {
    case databaseError(Error)
    case failedToRestore
    case startupTimeout
    
    public var description: String {
        switch self {
            case .databaseError(StorageError.startupFailed), .databaseError(DatabaseError.SQLITE_LOCKED), .databaseError(StorageError.databaseSuspended):
                return "Database startup failed"
            case .databaseError(StorageError.migrationNoLongerSupported): return "Unsupported version"
            case .failedToRestore: return "Failed to restore"
            case .databaseError: return "Database error"
            case .startupTimeout: return "Startup timeout"
        }
    }
    
    var message: String {
        switch self {
            case .databaseError(StorageError.startupFailed), .databaseError(DatabaseError.SQLITE_LOCKED), .databaseError(StorageError.databaseSuspended), .failedToRestore, .databaseError:
                return "databaseErrorGeneric"
                    .put(key: "app_name", value: Constants.app_name)
                    .localized()

            case .databaseError(StorageError.migrationNoLongerSupported):
                return "databaseErrorUpdate"
                    .put(key: "app_name", value: Constants.app_name)
                    .localized()
            
            case .startupTimeout:
                return "databaseErrorTimeout"
                    .put(key: "app_name", value: Constants.app_name)
                    .localized()
        }
    }
}
