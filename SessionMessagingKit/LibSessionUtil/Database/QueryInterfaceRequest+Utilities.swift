// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

// MARK: - GRDB

public extension QueryInterfaceRequest {
    @discardableResult
    func updateAllAndConfig(
        _ db: Database,
        _ assignments: ColumnAssignment...
    ) throws -> Int {
        return try updateAllAndConfig(db, assignments)
    }
    
    @discardableResult
    func updateAllAndConfig(
        _ db: Database,
        _ assignments: [ColumnAssignment]
    ) throws -> Int {
        switch self {
            case let contactRequest as QueryInterfaceRequest<Contact>:
                return try contactRequest.updateAndFetchAllAndUpdateConfig(db, assignments).count

            case let profileRequest as QueryInterfaceRequest<Profile>:
                return try profileRequest.updateAndFetchAllAndUpdateConfig(db, assignments).count
            
            default: return try self.updateAll(db, assignments)
        }
    }
}

public extension QueryInterfaceRequest where RowDecoder: FetchableRecord & TableRecord {
    @discardableResult
    func updateAndFetchAllAndUpdateConfig(
        _ db: Database,
        _ assignments: ColumnAssignment...
    ) throws -> [RowDecoder] {
        return try updateAndFetchAllAndUpdateConfig(db, assignments)
    }
    
    @discardableResult
    func updateAndFetchAllAndUpdateConfig(
        _ db: Database,
        _ assignments: [ColumnAssignment]
    ) throws -> [RowDecoder] {
        defer {
            db.afterNextTransaction { db in
                guard
                    self is QueryInterfaceRequest<Contact> ||
                    self is QueryInterfaceRequest<Profile> ||
                    self is QueryInterfaceRequest<ClosedGroup>
                else { return }
                
                // If we change one of these types then we may as well automatically enqueue
                // a new config sync job once the transaction completes
                ConfigurationSyncJob.enqueue(db)
            }
        }
        
        // FIXME: Remove this once `useSharedUtilForUserConfig` is permanent
        guard Features.useSharedUtilForUserConfig else {
            return try self.updateAndFetchAll(db, assignments)
        }
        
        // Update the config dump state where needed
        switch self {
            case is QueryInterfaceRequest<Contact>:
                return try SessionUtil.updatingContacts(db, try updateAndFetchAll(db, assignments))
                
            case is QueryInterfaceRequest<Profile>:
                return try SessionUtil.updatingProfiles(db, try updateAndFetchAll(db, assignments))
                
            default: return try self.updateAndFetchAll(db, assignments)
        }
    }
}
