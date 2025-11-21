// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct AnimatedToggle: View {
    let value: Bool
    let oldValue: Bool?
    let accessibility: Accessibility

    @State private var uiValue: Bool
    
    public init(
        value: Bool,
        oldValue: Bool?,
        accessibility: Accessibility
    ) {
        self.value = value
        self.oldValue = oldValue
        self.accessibility = accessibility
        _uiValue = State(initialValue: oldValue ?? value)
    }

    public var body: some View {
        Toggle("", isOn: $uiValue)
            .labelsHidden()
            .accessibility(accessibility)
            .task {
                guard (oldValue ?? value) != value else { return }
                try? await Task.sleep(nanoseconds: 10_000_000) // ~10ms
                withAnimation { uiValue = value }
            }
            .onChange(of: value) { new in
                withAnimation { uiValue = new }
            }
    }
}
