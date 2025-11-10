// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

// FIXME: After iOS 16+, we can use .scrollDisabled(true) instead

struct ScrollableList<Content: View>: View {
    let scrollable: Bool
    let content: () -> Content
    
    init(scrollable: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.scrollable = scrollable
        self.content = content
    }
    
    var body: some View {
        if scrollable {
            List { content() }
        } else {
            LazyVStack(alignment: .leading, spacing: 0) {
                content()
                    .padding(.horizontal, Values.mediumSpacing)
            }
        }
    }
}

