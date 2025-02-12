// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UIKit.UIImage
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

enum _023_GroupsExpiredFlag: Migration {
    static let target: TargetMigrations.Identifier = .messagingKit
    static let identifier: String = "GroupsExpiredFlag"
    static let minExpectedRunDuration: TimeInterval = 0.1
    static var requirements: [MigrationRequirement] = [.sessionIdCached, .libSessionStateLoaded]
    static var fetchedTables: [(FetchableRecord & TableRecord).Type] = []
    static var createdOrAlteredTables: [(FetchableRecord & TableRecord).Type] = [ClosedGroup.self]
    static let droppedTables: [(TableRecord & FetchableRecord).Type] = []
    
    static func migrate(_ db: Database, using dependencies: Dependencies) throws {
        try db.alter(table: ClosedGroup.self) { t in
            t.add(.expired, .boolean).defaults(to: false)
        }
        
        Storage.update(progress: 1, for: self, in: target, using: dependencies)
    }
    
    struct OpenGroupImageInfo: FetchableRecord, Decodable, ColumnExpressible {
        typealias Columns = CodingKeys
        enum CodingKeys: String, CodingKey, ColumnExpression, CaseIterable {
            case threadId
            case data = "imageData"
        }
        
        let threadId: String
        let data: Data
    }
}

