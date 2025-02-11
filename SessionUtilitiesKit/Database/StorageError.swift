// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum StorageError: Error {
    case generic
    case databaseInvalid
    case databaseSuspended
    case startupFailed
    case migrationFailed
    case migrationNoLongerSupported
    case invalidKeySpec
    case keySpecCreationFailed
    case keySpecInaccessible
    case decodingFailed
    case invalidQueryResult
    case transactionDeadlockTimeout
    
    case failedToSave
    case objectNotFound
    case objectNotSaved
    
    case invalidSearchPattern
    case invalidData
    
    case devRemigrationRequired
}
