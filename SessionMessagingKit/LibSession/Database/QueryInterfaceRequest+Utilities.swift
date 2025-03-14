// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

// MARK: - ConfigColumnAssignment

public struct ConfigColumnAssignment {
    var column: ColumnExpression
    var assignment: ColumnAssignment
    
    init(
        column: ColumnExpression,
        assignment: ColumnAssignment
    ) {
        self.column = column
        self.assignment = assignment
    }
}

// MARK: - ColumnExpression

extension ColumnExpression {
    public func set(to value: (any SQLExpressible)?) -> ConfigColumnAssignment {
        ConfigColumnAssignment(column: self, assignment: self.set(to: value))
    }
}

// MARK: - QueryInterfaceRequest

public extension QueryInterfaceRequest where RowDecoder: FetchableRecord & TableRecord {
    
    // MARK: -- updateAll
    
    @discardableResult
    func updateAll(
        _ db: Database,
        _ assignments: ConfigColumnAssignment...
    ) throws -> Int {
        return try updateAll(db, assignments)
    }
    
    @discardableResult
    func updateAll(
        _ db: Database,
        _ assignments: [ConfigColumnAssignment]
    ) throws -> Int {
        return try self.updateAll(db, assignments.map { $0.assignment })
    }
    
    @discardableResult
    func updateAllAndConfig(
        _ db: Database,
        _ assignments: ConfigColumnAssignment...,
        using dependencies: Dependencies
    ) throws -> Int {
        return try updateAllAndConfig(
            db,
            assignments,
            using: dependencies
        )
    }
    
    @discardableResult
    func updateAllAndConfig(
        _ db: Database,
        _ assignments: [ConfigColumnAssignment],
        using dependencies: Dependencies
    ) throws -> Int {
        let targetAssignments: [ColumnAssignment] = assignments.map { $0.assignment }
        
        // Before we do anything custom make sure the changes actually do need to be synced
        guard LibSession.assignmentsRequireConfigUpdate(assignments) else {
            return try self.updateAll(db, targetAssignments)
        }
        
        return try self.updateAndFetchAllAndUpdateConfig(
            db,
            assignments,
            using: dependencies
        ).count
    }
    
    // MARK: -- updateAndFetchAll
    
    @discardableResult
    func updateAndFetchAllAndUpdateConfig(
        _ db: Database,
        _ assignments: ConfigColumnAssignment...,
        using dependencies: Dependencies
    ) throws -> [RowDecoder] {
        return try updateAndFetchAllAndUpdateConfig(
            db,
            assignments,
            using: dependencies
        )
    }
    
    @discardableResult
    func updateAndFetchAllAndUpdateConfig(
        _ db: Database,
        _ assignments: [ConfigColumnAssignment],
        using dependencies: Dependencies
    ) throws -> [RowDecoder] {
        // First perform the actual updates
        let updatedData: [RowDecoder] = try self.updateAndFetchAll(db, assignments.map { $0.assignment })
        
        // Then check if any of the changes could affect the config
        guard LibSession.assignmentsRequireConfigUpdate(assignments) else { return updatedData }
        
        // Update the config dump state where needed
        switch self {
            case is QueryInterfaceRequest<Contact>:
                return try LibSession.updatingContacts(db, updatedData, using: dependencies)
                
            case is QueryInterfaceRequest<Profile>:
                return try LibSession.updatingProfiles(db, updatedData, using: dependencies)
                
            case is QueryInterfaceRequest<SessionThread>:
                return try LibSession.updatingThreads(db, updatedData, using: dependencies)
            
            case is QueryInterfaceRequest<ClosedGroup>:
                // Group data is stored both in the `USER_GROUPS` config and it's own `GROUP_INFO` config so we
                // need to update both
                try LibSession.updatingGroups(db, updatedData, using: dependencies)
                return try LibSession.updatingGroupInfo(db, updatedData, using: dependencies)
                
            case is QueryInterfaceRequest<GroupMember>:
                return try LibSession.updatingGroupMembers(db, updatedData, using: dependencies)
                
            case is QueryInterfaceRequest<DisappearingMessagesConfiguration>:
                try LibSession.updatingDisappearingConfigsOneToOne(db, updatedData, using: dependencies)
                return try LibSession.updatingDisappearingConfigsGroups(db, updatedData, using: dependencies)
                
            default: return updatedData
        }
    }
}
