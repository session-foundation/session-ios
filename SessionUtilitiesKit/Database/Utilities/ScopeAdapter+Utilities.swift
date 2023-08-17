// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB

public extension ScopeAdapter {
    static func with<VM: ColumnExpressible>(
        _ viewModel: VM.Type,
        _ scopes: [VM.Columns: RowAdapter]
    ) -> ScopeAdapter {
        return ScopeAdapter(scopes.reduce(into: [:]) { result, next in result[next.key.name] = next.value })
    }
}
