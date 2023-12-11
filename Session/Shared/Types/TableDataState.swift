// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import DifferenceKit

public protocol TableData {
    associatedtype TableItem: Hashable & Differentiable
}

public protocol SectionedTableData: TableData {
    associatedtype Section: SessionTableSection
    
    typealias SectionModel = ArraySection<Section, SessionCell.Info<TableItem>>
}

public class TableDataState<Section: SessionTableSection, TableItem: Hashable & Differentiable>: SectionedTableData {
    public private(set) var tableData: [SectionModel]  = []
    
    public func updateTableData(_ updatedData: [SectionModel]) { self.tableData = updatedData }
}
