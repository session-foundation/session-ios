// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum SessionListScreenContent {}

public extension SessionListScreenContent {
    protocol ViewModelType: ObservableObject, SectionedListItemData {
        var title: String { get }
        var state: ListItemDataState<Section, ListItem> { get }
    }
}
