// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct AttributedLabel: UIViewRepresentable {
    public typealias UIViewType = UILabel

    let themedAttributedString: ThemedAttributedString?
    let maxWidth: CGFloat?

    public init(_ themedAttributedString: ThemedAttributedString?, maxWidth: CGFloat? = nil) {
        self.themedAttributedString = themedAttributedString
        self.maxWidth = maxWidth
    }

    public func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.themeAttributedText = themedAttributedString
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return label
    }

    public func updateUIView(_ label: UILabel, context: Context) {
        label.themeAttributedText = themedAttributedString
        if let maxWidth = maxWidth {
            label.preferredMaxLayoutWidth = maxWidth
        }
    }
}
