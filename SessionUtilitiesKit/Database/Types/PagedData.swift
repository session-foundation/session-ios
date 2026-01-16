// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public enum PagedData {
    public static let autoLoadNextPageDelay: DispatchTimeInterval = .milliseconds(400)
}

// MARK: - PagedData.PageInfo

public extension PagedData {
    struct LoadedInfo<ID: DatabaseValueConvertible & Sendable & Hashable>: Sendable, Equatable, ThreadSafeType {
        fileprivate let queryInfo: QueryInfo
        
        public let pageSize: Int
        public let totalCount: Int
        public let firstPageOffset: Int
        public let currentIds: [ID]
        
        public var firstIndex: Int { firstPageOffset }
        public var lastIndex: Int { firstPageOffset + currentIds.count - 1 }
        public var hasPrevPage: Bool { firstPageOffset > 0 }
        public var hasNextPage: Bool { (firstPageOffset + currentIds.count) < totalCount }
        public var asResult: LoadResult<ID> { LoadResult<ID>(info: self, newIds: []) }
        
        // MARK: - Initialization
        
        public init<FetchedRecord: PagableRecord>(
            record: FetchedRecord.Type,
            pageSize: Int,
            requiredJoinSQL: SQL?,
            filterSQL: SQL,
            groupSQL: SQL?,
            orderSQL: SQL
        ) {
            self.queryInfo = QueryInfo(
                tableName: record.PagedDataType.databaseTableName,
                idColumnName: record.PagedDataType.idColumn.name,
                requiredJoinSQL: requiredJoinSQL,
                filterSQL: filterSQL,
                groupSQL: groupSQL,
                orderSQL: orderSQL
            )
            self.pageSize = pageSize
            self.totalCount = 0
            self.firstPageOffset = 0
            self.currentIds = []
        }
        
        fileprivate init(
            queryInfo: QueryInfo,
            pageSize: Int,
            totalCount: Int,
            firstPageOffset: Int,
            currentIds: [ID]
        ) {
            self.queryInfo = queryInfo
            self.pageSize = pageSize
            self.totalCount = totalCount
            self.firstPageOffset = firstPageOffset
            self.currentIds = currentIds
        }
        
        public func with(filterSQL: SQL) -> LoadedInfo {
            return LoadedInfo(
                queryInfo: QueryInfo(
                    tableName: queryInfo.tableName,
                    idColumnName: queryInfo.idColumnName,
                    requiredJoinSQL: queryInfo.requiredJoinSQL,
                    filterSQL: filterSQL,
                    groupSQL: queryInfo.groupSQL,
                    orderSQL: queryInfo.orderSQL
                ),
                pageSize: pageSize,
                totalCount: totalCount,
                firstPageOffset: firstPageOffset,
                currentIds: currentIds
            )
        }
    }
    
    struct LoadResult<ID: DatabaseValueConvertible & Sendable & Hashable> {
        public let info: PagedData.LoadedInfo<ID>
        public let newIds: [ID]
        
        public init(info: PagedData.LoadedInfo<ID>, newIds: [ID] = []) {
            self.info = info
            self.newIds = newIds
        }
        
        public static func createInvalid() -> LoadResult<ID> {
            LoadResult(
                info: PagedData.LoadedInfo(
                    queryInfo: PagedData.QueryInfo(
                        tableName: "",
                        idColumnName: "",
                        requiredJoinSQL: nil,
                        filterSQL: "",
                        groupSQL: nil,
                        orderSQL: ""
                    ),
                    pageSize: 0,
                    totalCount: 0,
                    firstPageOffset: 0,
                    currentIds: []
                ),
                newIds: []
            )
        }
    }
    
    @available(*, deprecated, message: "This type was used with the PagedDatabaseObserver but that is deprecated, use the ObservationBuilder instead and PagedData.LoadedInfo")
    struct PageInfo: Equatable, ThreadSafeType {
        public let pageSize: Int
        public let pageOffset: Int
        public let currentCount: Int
        public let totalCount: Int
        
        // MARK: - Initizliation
        
        public init(
            pageSize: Int,
            pageOffset: Int = 0,
            currentCount: Int = 0,
            totalCount: Int = 0
        ) {
            self.pageSize = pageSize
            self.pageOffset = pageOffset
            self.currentCount = currentCount
            self.totalCount = totalCount
        }
    }
    
    fileprivate struct QueryInfo: Equatable {
        fileprivate let tableName: String
        fileprivate let idColumnName: String
        fileprivate let requiredJoinSQL: SQL?
        fileprivate let filterSQL: SQL
        fileprivate let groupSQL: SQL?
        fileprivate let orderSQL: SQL
        fileprivate let hasResolvedQueries: Bool
        
        /// The `SQL` type isn't equatable so we use this type to generate `String` versions of the queries so that we can still
        /// equate the values
        let requiredJoin: String?
        let requiredJoinArguments: StatementArguments?
        let filter: String
        let filterArguments: StatementArguments
        let group: String?
        let groupArguments: StatementArguments?
        let order: String
        let orderArguments: StatementArguments
        
        init(
            tableName: String,
            idColumnName: String,
            requiredJoinSQL: SQL?,
            filterSQL: SQL,
            groupSQL: SQL?,
            orderSQL: SQL
        ) {
            self.tableName = tableName
            self.idColumnName = idColumnName
            self.requiredJoinSQL = requiredJoinSQL
            self.filterSQL = filterSQL
            self.groupSQL = groupSQL
            self.orderSQL = orderSQL
            self.hasResolvedQueries = false
            
            self.requiredJoin = ""
            self.requiredJoinArguments = nil
            self.filter = ""
            self.filterArguments = StatementArguments()
            self.group = ""
            self.groupArguments = nil
            self.order = ""
            self.orderArguments = StatementArguments()
        }
        
        init(
            _ db: ObservingDatabase,
            tableName: String,
            idColumnName: String,
            requiredJoinSQL: SQL?,
            filterSQL: SQL,
            groupSQL: SQL?,
            orderSQL: SQL
        ) throws {
            self.tableName = tableName
            self.idColumnName = idColumnName
            self.requiredJoinSQL = requiredJoinSQL
            self.filterSQL = filterSQL
            self.groupSQL = groupSQL
            self.orderSQL = orderSQL
            self.hasResolvedQueries = true
            
            /// Build the Queries
            let requiredJoinResult = try requiredJoinSQL.map { try $0.build(db.originalDb) }
            let filterResult = try filterSQL.build(db.originalDb)
            let groupResult = try groupSQL.map { try $0.build(db.originalDb) }
            let orderResult = try orderSQL.build(db.originalDb)
            
            /// Store the built versions
            self.requiredJoin = requiredJoinResult?.sql
            self.requiredJoinArguments = requiredJoinResult?.arguments
            self.filter = filterResult.sql
            self.filterArguments = filterResult.arguments
            self.group = groupResult?.sql
            self.groupArguments = groupResult?.arguments
            self.order = orderResult.sql
            self.orderArguments = orderResult.arguments
        }
        
        fileprivate func resolveIfNeeded(_ db: ObservingDatabase) throws -> QueryInfo {
            guard !hasResolvedQueries else { return self }
            
            return try QueryInfo(
                db,
                tableName: tableName,
                idColumnName: idColumnName,
                requiredJoinSQL: requiredJoinSQL,
                filterSQL: filterSQL,
                groupSQL: groupSQL,
                orderSQL: orderSQL
            )
        }
        
        // MARK: - Equatable Conformance
        
        public static func == (lhs: QueryInfo, rhs: QueryInfo) -> Bool {
            return (
                lhs.tableName == rhs.tableName &&
                lhs.requiredJoin == rhs.requiredJoin &&
                lhs.requiredJoinArguments == rhs.requiredJoinArguments &&
                lhs.filter == rhs.filter &&
                lhs.filterArguments == rhs.filterArguments &&
                lhs.group == rhs.group &&
                lhs.groupArguments == rhs.groupArguments &&
                lhs.order == rhs.order &&
                lhs.orderArguments == rhs.orderArguments
            )
        }
    }
}

// MARK: - PagedData.Target

public extension PagedData {
    enum Target<ID: SQLExpressible & Sendable & Hashable>: Sendable {
        /// This will attempt to load the first page of data
        case initial
        
        /// This will attempt to load a page of data around a specified id
        ///
        /// **Note:** This target will only work if there is no other data in the cache
        case initialPageAround(id: ID)
        
        /// This will attempt to load a page of data before the first item in the cache
        case pageBefore
        
        /// This will attempt to load a page of data after the last item in the cache
        case pageAfter
        
        /// This will attempt to load the next `count` items before the first item in the cache
        case numberBefore(count: Int)
        
        /// This will attempt to load the next `count` items after the last item in the cache
        case numberAfter(count: Int)
        
        /// This will jump to the specified id, loading a page around it and clearing out any
        /// data that was previously cached
        ///
        /// **Note:** If the id is already within the cache then this will do nothing, if it's within a single `pageSize` of the currently
        /// cached data (plus the padding amount) then it'll load up to that data (plus padding)
        case jumpTo(id: ID, padding: Int)
        
        /// This will refetch all of the currently fetched data
        case reloadCurrent(insertedIds: Set<ID>, deletedIds: Set<ID>)
        
        /// This will load the new items added in a specific update
        ///
        /// **Note:** This `Target` should not be used if existing items can be modified as a result of other items being inserted
        /// or deleted
        case newItems(insertedIds: Set<ID>, deletedIds: Set<ID>)
        
        public var reloadCurrent: Target<ID> { .reloadCurrent(insertedIds: [], deletedIds: []) }
        public static func reloadCurrent(insertedIds: Set<ID>) -> Target<ID> {
            return .reloadCurrent(insertedIds: insertedIds, deletedIds: [])
        }
        
        public static func reloadCurrent(deletedIds: Set<ID>) -> Target<ID> {
            return .reloadCurrent(insertedIds: [], deletedIds: deletedIds)
        }
    }
}

// MARK: - PagableRecord

public protocol PagableRecord: Identifiable {
    associatedtype PagedDataType: IdentifiableTableRecord
}

public protocol IdentifiableTableRecord: TableRecord & Identifiable {
    static var idColumn: ColumnExpression { get }
}

// MARK: - PagedData.LoadedInfo Convenience

public extension PagedData.LoadedInfo {
    func load(
        _ db: ObservingDatabase,
        _ target: PagedData.Target<ID>
    ) throws -> PagedData.LoadResult<ID> {
        var newOffset: Int
        var newLimit: Int
        var newFirstPageOffset: Int
        var mergeStrategy: ([ID], [ID]) -> [ID]
        var newIdStrategy: ([ID], [ID]) -> [ID]
        let newTotalCount: Int = PagedData.totalCount(
            db,
            tableName: queryInfo.tableName,
            requiredJoinSQL: queryInfo.requiredJoinSQL,
            filterSQL: queryInfo.filterSQL
        )
        
        switch target {
            case .initial:
                newOffset = 0
                newLimit = pageSize
                newFirstPageOffset = 0
                mergeStrategy = { _, new in new } // Replace old with new
                newIdStrategy = { _, new in new } // Only newly fetched
                
            case .pageBefore:
                newLimit = min(firstPageOffset, pageSize)
                newOffset = max(0, firstPageOffset - newLimit)
                newFirstPageOffset = newOffset
                mergeStrategy = { old, new in (new + old) } // Prepend new page
                newIdStrategy = { _, new in new }           // Only newly fetched
                
            case .pageAfter:
                newOffset = firstPageOffset + currentIds.count
                newLimit = pageSize
                newFirstPageOffset = firstPageOffset
                mergeStrategy = { old, new in (old + new) } // Append new page
                newIdStrategy = { _, new in new }           // Only newly fetched
                
            case .numberBefore(let count):
                newLimit = count
                newOffset = max(0, firstPageOffset - newLimit)
                newFirstPageOffset = newOffset
                mergeStrategy = { old, new in (new + old) } // Prepend new items
                newIdStrategy = { _, new in new }           // Only newly fetched
                
            case .numberAfter(let count):
                newOffset = firstPageOffset + currentIds.count
                newLimit = count
                newFirstPageOffset = firstPageOffset
                mergeStrategy = { old, new in (old + new) } // Append new items
                newIdStrategy = { _, new in new }           // Only newly fetched
                
            case .initialPageAround(let id):
                let maybeIndex: Int? = PagedData.index(
                    db,
                    for: id,
                    tableName: queryInfo.tableName,
                    idColumn: queryInfo.idColumnName,
                    requiredJoinSQL: queryInfo.requiredJoinSQL,
                    orderSQL: queryInfo.orderSQL,
                    filterSQL: queryInfo.filterSQL
                )
                
                guard let targetIndex: Int = maybeIndex else {
                    return try self.load(db, .initial)
                }
                
                let halfPage: Int = (pageSize / 2)
                newOffset = max(0, targetIndex - halfPage)
                newLimit = pageSize
                newFirstPageOffset = newOffset
                mergeStrategy = { _, new in new }   // Replace old with new
                newIdStrategy = { _, new in new }   // Only newly fetched
                
            case .jumpTo(let targetId, let padding):
                /// If it's already loaded then no need to do anything
                guard !currentIds.contains(targetId) else { return PagedData.LoadResult<ID>(info: self) }
                
                /// If we want to focus on a specific item then we need to find it's index in the queried data
                let maybeIndex: Int? = PagedData.index(
                    db,
                    for: targetId,
                    tableName: queryInfo.tableName,
                    idColumn: queryInfo.idColumnName,
                    requiredJoinSQL: queryInfo.requiredJoinSQL,
                    orderSQL: queryInfo.orderSQL,
                    filterSQL: queryInfo.filterSQL
                )
                
                /// If the id doesn't exist then we can't jump to it so just return the current state
                guard let targetIndex: Int = maybeIndex else {
                    return PagedData.LoadResult<ID>(info: self)
                }
                
                /// If the `targetIndex` is over a page before the current content or more than a page after the current content
                /// then we want to reload the entire content (to avoid loading an excessive amount of data), otherwise we should
                /// load all messages between the current content and the `targetIndex` (plus padding)
                let isCloseBefore: Bool = (targetIndex >= (firstPageOffset - pageSize) && targetIndex < firstPageOffset)
                let isCloseAfter: Bool = (targetIndex > lastIndex && targetIndex <= (lastIndex + pageSize))
                
                if isCloseBefore {
                    newOffset = max(0, targetIndex - padding)
                    newLimit = firstPageOffset - newOffset
                    newFirstPageOffset = newOffset
                    mergeStrategy = { old, new in (new + old) } // Prepend new page
                    newIdStrategy = { _, new in new }           // Only newly fetched
                }
                else if isCloseAfter {
                    newOffset = lastIndex + 1
                    newLimit = (targetIndex - lastIndex) + padding
                    newFirstPageOffset = firstPageOffset
                    mergeStrategy = { old, new in (old + new) } // Append new page
                    newIdStrategy = { _, new in new }           // Only newly fetched
                }
                else {
                    /// The target is too far away so we need to do a new fetch
                    return try load(db, .initialPageAround(id: targetId))
                }
            
            case .reloadCurrent(let insertedIds, let deletedIds):
                let finalSet: Set<ID> = Set(currentIds).union(insertedIds).subtracting(deletedIds)
                newOffset = self.firstPageOffset
                newLimit = max(pageSize, finalSet.count)
                newFirstPageOffset = self.firstPageOffset
                mergeStrategy = { _, new in new }               // Replace old with new
                newIdStrategy = { _, fetchedIds in fetchedIds } // Consider all as new
            
            case .newItems(let insertedIds, let deletedIds):
                let finalSet: Set<ID> = Set(currentIds).union(insertedIds).subtracting(deletedIds)
                newOffset = self.firstPageOffset
                newLimit = max(pageSize, finalSet.count)
                newFirstPageOffset = self.firstPageOffset
                mergeStrategy = { _, new in new }                                // Replace old with new
                newIdStrategy = { old, new in new.filter { !old.contains($0) } } // Only newly fetched
        }
        
        /// Now that we have the limit and offset actually load the data
        let newIds: [ID] = try PagedData.ids(
            db,
            tableName: queryInfo.tableName,
            idColumn: queryInfo.idColumnName,
            requiredJoinSQL: queryInfo.requiredJoinSQL,
            filterSQL: queryInfo.filterSQL,
            groupSQL: queryInfo.groupSQL,
            orderSQL: queryInfo.orderSQL,
            limit: newLimit,
            offset: newOffset
        )
        
        return PagedData.LoadResult<ID>(
            info: PagedData.LoadedInfo(
                queryInfo: try queryInfo.resolveIfNeeded(db),
                pageSize: pageSize,
                totalCount: newTotalCount,
                firstPageOffset: newFirstPageOffset,
                currentIds: mergeStrategy(currentIds, newIds)
            ),
            newIds: newIdStrategy(currentIds, newIds)
        )
    }
}

// MARK: - PagedData.LoadResult Convenience

public extension PagedData.LoadResult {
    func load(_ db: ObservingDatabase, target: PagedData.Target<ID>) throws -> PagedData.LoadResult<ID> {
        let result: PagedData.LoadResult<ID> = try info.load(db, target)
        
        guard !newIds.isEmpty else { return result }
        
        return PagedData.LoadResult<ID>(info: info, newIds: (newIds + result.newIds))
    }
}

// MARK: - PagedData Queries

internal extension PagedData {
    struct RowInfo: Codable, FetchableRecord {
        let rowId: Int64
        let rowIndex: Int
    }
    struct RowIdPair<ID: Codable>: Codable, FetchableRecord {
        let rowId: Int64
        let id: ID
    }
    
    static func totalCount(
        _ db: ObservingDatabase,
        tableName: String,
        requiredJoinSQL: SQL?,
        filterSQL: SQL
    ) -> Int {
        let tableNameLiteral: SQL = SQL(stringLiteral: tableName)
        let finalJoinSQL: SQL = (requiredJoinSQL ?? "")
        let request: SQLRequest<Int> = """
            SELECT \(tableNameLiteral).rowId
            FROM \(tableNameLiteral)
            \(finalJoinSQL)
            WHERE \(filterSQL)
        """
        
        return (try? request.fetchCount(db))
            .defaulting(to: 0)
    }
    
    fileprivate static func ids<ID: DatabaseValueConvertible & SQLExpressible>(
        _ db: ObservingDatabase,
        tableName: String,
        idColumn: String,
        requiredJoinSQL: SQL?,
        filterSQL: SQL,
        groupSQL: SQL?,
        orderSQL: SQL,
        limit: Int,
        offset: Int
    ) throws -> [ID] {
        let tableNameLiteral: SQL = SQL(stringLiteral: tableName)
        let idColumnLiteral: SQL = SQL(stringLiteral: idColumn)
        let finalJoinSQL: SQL = (requiredJoinSQL ?? "")
        let finalGroupSQL: SQL = (groupSQL ?? "")
        let request: SQLRequest<ID> = """
            SELECT \(tableNameLiteral).\(idColumnLiteral) as id
            FROM \(tableNameLiteral)
            \(finalJoinSQL)
            WHERE \(filterSQL)
            \(finalGroupSQL)
            ORDER BY \(orderSQL)
            LIMIT \(limit) OFFSET \(offset)
        """
        
        return try request.fetchAll(db)
    }
    
    static func index<ID: SQLExpressible>(
        _ db: ObservingDatabase,
        for id: ID,
        tableName: String,
        idColumn: String,
        requiredJoinSQL: SQL?,
        orderSQL: SQL,
        filterSQL: SQL
    ) -> Int? {
        let tableNameLiteral: SQL = SQL(stringLiteral: tableName)
        let idColumnLiteral: SQL = SQL(stringLiteral: idColumn)
        let finalJoinSQL: SQL = (requiredJoinSQL ?? "")
        let request: SQLRequest<Int> = """
            SELECT
                (data.rowIndex - 1) AS rowIndex -- Converting from 1-Indexed to 0-indexed
            FROM (
                SELECT
                    \(tableNameLiteral).rowId AS rowId,
                    \(tableNameLiteral).\(idColumnLiteral) AS \(idColumnLiteral),
                    ROW_NUMBER() OVER (ORDER BY \(orderSQL)) AS rowIndex
                FROM \(tableNameLiteral)
                \(finalJoinSQL)
                WHERE \(filterSQL)
            ) AS data
            WHERE \(SQL("data.\(idColumnLiteral) = \(id)"))
        """
        
        return try? request.fetchOne(db)
    }
}
