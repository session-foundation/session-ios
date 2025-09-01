// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public enum SessionListScreenContent {}

public extension SessionListScreenContent {
    protocol ViewModelType: ObservableObject, SectionedListItemData {
        var dependencies: Dependencies { get }
        var state: ListItemDataState<Section, ListItem> { get }
    }
}
