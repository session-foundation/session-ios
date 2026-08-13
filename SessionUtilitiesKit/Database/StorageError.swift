// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum StorageError: Error {
    case generic
    case databaseInvalid
    case databaseSuspended
    case startupFailed

    /// A database file exists but its encryption key does not, so it can never be opened
    ///
    /// Distinct from `startupFailed` because it is the one startup failure that is definitely unrecoverable in
    /// place, which makes offering to reset the database the correct remedy rather than a destructive guess. A
    /// missing key with **no** database is an ordinary fresh install and is not this case
    case databaseKeyMissingWithActiveDatabase
    case migrationFailed
    case migrationNoLongerSupported
    case decodingFailed
    case invalidQueryResult
    
    /// This error is thrown when a synchronous operation takes longer than `Storage.transactionDeadlockTimeoutSeconds`,
    /// the assumption being that if we know an operation is going to take a long time then we should probably be handling it asynchronously
    /// rather than a synchronous way
    case transactionDeadlockTimeout
    case validStorageIncorrectlyHandledAsError
    
    case failedToSave
    case objectNotFound
    case objectNotSaved
    
    case invalidSearchPattern
    case invalidData
    
    case devRemigrationRequired
}
