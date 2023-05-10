// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public protocol Migration {
    static var target: TargetMigrations.Identifier { get }
    static var identifier: String { get }
    static var needsConfigSync: Bool { get }
    static var minExpectedRunDuration: TimeInterval { get }
    
    static func migrate(_ db: Database) throws
}

public extension Migration {
    static func loggedMigrate(_ targetIdentifier: TargetMigrations.Identifier) -> ((_ db: Database) throws -> ()) {
        return { (db: Database) in
            SNLogNotTests("[Migration Info] Starting \(targetIdentifier.key(with: self))")
            Storage.shared.internalCurrentlyRunningMigration.mutate { $0 = (targetIdentifier, self) }
            do { try migrate(db) }
            catch {
                Storage.shared.internalCurrentlyRunningMigration.mutate { $0 = nil }
                throw error
            }
            SNLogNotTests("[Migration Info] Completed \(targetIdentifier.key(with: self))")
        }
    }
}
