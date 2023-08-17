// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public class TypedTableAlias<T> where T: TableRecord, T: ColumnExpressible {
    internal let name: String
    internal let tableName: String
    public let alias: TableAlias
    
    public init(name: String = T.databaseTableName) {
        self.name = name
        self.tableName = T.databaseTableName
        self.alias = TableAlias(name: name)
    }
    
    public subscript(_ column: T.Columns) -> SQLExpression {
        return alias[column.name]
    }
    
    /// **Warning:** For this to work you **MUST** call the '.aliased()' method when joining or it will
    /// throw when trying to decode
    public func allColumns() -> SQLSelection {
        return alias[AllColumns().sqlSelection]
    }
}

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
    public func allColumns() -> SQLSelection {
        return self[AllColumns().sqlSelection]
    }
}
