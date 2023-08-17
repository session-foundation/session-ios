// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public extension SQLInterpolation {
    /// Appends the table name of the record type.
    ///
    ///     // SELECT * FROM player
    ///     let player: TypedTableAlias<T> = TypedTableAlias()
    ///     let request: SQLRequest<Player> = "SELECT * FROM \(player)"
    @_disfavoredOverload
    mutating func appendInterpolation<T>(_ typedTableAlias: TypedTableAlias<T>) {
        let name: String = typedTableAlias.name
        let tableName: String = typedTableAlias.tableName
        
        guard name != tableName else { return appendLiteral(tableName.quotedDatabaseIdentifier) }
        
        appendLiteral("\(tableName.quotedDatabaseIdentifier) AS \(name.quotedDatabaseIdentifier)")
    }
}
