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
        
        guard let tableName: String = typedTableAlias.tableName else { return appendLiteral(name.quotedDatabaseIdentifier) }
        guard name != tableName else { return appendLiteral(tableName.quotedDatabaseIdentifier) }
        
        appendLiteral("\(tableName.quotedDatabaseIdentifier) AS \(name.quotedDatabaseIdentifier)")
    }
    
    /// Appends a simple SQL query for use when we want a `LEFT JOIN` that will always fail
    ///
    ///     // SELECT * FROM player LEFT JOIN team AS testTeam ON false
    ///     let player: TypedTableAlias<Player> = TypedTableAlias()
    ///     let testTeam: TypedTableAlias<Team> = TypedTableAlias(name: "testTeam")
    ///     let request: SQLRequest<Player> = "SELECT * FROM \(player) LEFT JOIN \(testTeam.never)
    @_disfavoredOverload
    mutating func appendInterpolation<T: ColumnExpressible>(_ neverJoiningAlias: NeverJoiningTypedTableAlias<T>) where T: TableRecord {
        guard let tableName: String = neverJoiningAlias.alias.tableName else {
            appendLiteral("(SELECT \(generateSelection(for: T.self))) AS \(neverJoiningAlias.alias.name.quotedDatabaseIdentifier) ON false")
            return
        }
        
        appendLiteral("\(tableName.quotedDatabaseIdentifier) AS \(neverJoiningAlias.alias.name.quotedDatabaseIdentifier) ON false")
    }
    
    /// Appends a simple SQL query for use when we want a `LEFT JOIN` that will always fail
    ///
    ///     // SELECT * FROM player LEFT JOIN (SELECT 0 AS teamInfo.Column.A, 0 AS teamInfo.Column.B) AS teamInfo ON false
    ///     let player: TypedTableAlias<Player> = TypedTableAlias()
    ///     let teamInfo: TypedTableAlias<TeamInfo> = TypedTableAlias(name: "teamInfo")
    ///     let request: SQLRequest<Player> = "SELECT * FROM \(player) LEFT JOIN \(teamInfo.never)
    @_disfavoredOverload
    mutating func appendInterpolation<T: ColumnExpressible>(_ neverJoiningAlias: NeverJoiningTypedTableAlias<T>) where T.Columns: CaseIterable {
        appendLiteral("(SELECT \(generateSelection(for: T.self))) AS \(neverJoiningAlias.alias.name.quotedDatabaseIdentifier) ON false")
    }
    
    /// Appends a simple SQL query for use when we want a `LEFT JOIN` that will always fail
    ///
    ///     // SELECT * FROM player LEFT JOIN (SELECT 0 AS teamInfo.Column.A, 0 AS teamInfo.Column.B) AS teamInfo ON false
    ///     let player: TypedTableAlias<Player> = TypedTableAlias()
    ///     let teamInfo: TypedTableAlias<TeamInfo> = TypedTableAlias(name: "teamInfo")
    ///     let request: SQLRequest<Player> = "SELECT * FROM \(player) LEFT JOIN \(teamInfo.never)
    @_disfavoredOverload
    mutating func appendInterpolation<T: ColumnExpressible>(_ neverJoiningAlias: NeverJoiningTypedTableAlias<T>) {
        appendLiteral("(SELECT \(generateSelection(for: T.self))) AS \(neverJoiningAlias.alias.name.quotedDatabaseIdentifier) ON false")
    }
    
    private func generateSelection<T: ColumnExpressible>(for type: T.Type) -> String where T.Columns: CaseIterable {
        return T.Columns.allCases
            .map { "NULL AS \($0.name)" }
            .joined(separator: ", ")
    }
    
    private func generateSelection<T: ColumnExpressible>(for type: T.Type) -> String {
        return "SELECT 1"
    }
}
