// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public struct TypedTableAlias<T: ColumnExpressible> {
    public enum RowIdColumn {
        case rowId
    }
    
    internal let name: String
    internal let tableName: String?
    internal let alias: TableAlias
    
    public var allColumns: SQLSelection { alias[AllColumns().sqlSelection] }
    public var never: NeverJoiningTypedTableAlias<T> { NeverJoiningTypedTableAlias<T>(alias: self) }
    
    // MARK: - Initialization
    
    public init(name: String, tableName: String? = nil) {
        self.name = name
        self.tableName = tableName
        self.alias = TableAlias(name: name)
    }
    
    public init(name: String) where T: TableRecord {
        self.name = name
        self.tableName = T.databaseTableName
        self.alias = TableAlias(name: name)
    }
    
    public init() where T: TableRecord {
        self = TypedTableAlias(name: T.databaseTableName)
    }
    
    public init<VM: ColumnExpressible>(_ viewModel: VM.Type, column: VM.Columns, tableName: String?) {
        self.name = column.name
        self.tableName = tableName
        self.alias = TableAlias(name: name)
    }
    
    public init<VM: ColumnExpressible>(_ viewModel: VM.Type, column: VM.Columns) where T: TableRecord {
        self = TypedTableAlias(viewModel, column: column, tableName: T.databaseTableName)
    }
    
    // MARK: - Functions
    
    public subscript(_ column: T.Columns) -> SQLExpression {
        return alias[column.name]
    }
    
    public subscript(_ column: RowIdColumn) -> SQLSelection {
        return alias[Column.rowID]
    }
}

// MARK: - NeverJoiningTypedTableAlias

public struct NeverJoiningTypedTableAlias<T: ColumnExpressible> {
    internal let alias: TypedTableAlias<T>
}

// MARK: - Extensions

extension QueryInterfaceRequest {
    public func aliased<T>(_ typedAlias: TypedTableAlias<T>) -> Self {
        return aliased(typedAlias.alias)
    }
}

extension Association {
    public func aliased<T>(_ typedAlias: TypedTableAlias<T>) -> Self {
        return aliased(typedAlias.alias)
    }
}

extension TableAlias {
    public var allColumns: SQLSelection { self[AllColumns().sqlSelection] }
}
