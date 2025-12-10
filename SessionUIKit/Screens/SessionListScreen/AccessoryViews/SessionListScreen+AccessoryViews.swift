// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import Lucide

public extension SessionListScreenContent {
    struct ListItemAccessory: Hashable, Equatable {
        @ViewBuilder public let accessoryView: () -> AnyView
        
        public init<Accessory: View>(
            @ViewBuilder accessoryView: @escaping () -> Accessory
        ) {
            self.accessoryView = { accessoryView().eraseToAnyView() }
        }
        
        public func hash(into hasher: inout Hasher) {}
        public static func == (lhs: ListItemAccessory, rhs: ListItemAccessory) -> Bool {
            return false
        }
    }
}
