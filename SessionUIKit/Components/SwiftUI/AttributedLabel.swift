// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct AttributedLabel: UIViewRepresentable {
    /// A `UILabel` wraps against `preferredMaxLayoutWidth`, and a caller laying one out in SwiftUI usually has no
    /// width to give it - so it takes its own, which is the only point at which the real one is known. Without this
    /// the label measures as a single line however many it is allowed, and either widens its container or truncates
    /// early
    public class SelfSizingLabel: UILabel {
        /// A ceiling from the caller, where it had one to give. The bounds alone are not enough: a label already
        /// laid out too wide would wrap against that width and keep itself there
        var explicitMaxWidth: CGFloat?
        
        public override func layoutSubviews() {
            super.layoutSubviews()
            
            let target: CGFloat = min(bounds.width, (explicitMaxWidth ?? .greatestFiniteMagnitude))
            
            guard target > 0, preferredMaxLayoutWidth != target else { return }
            
            preferredMaxLayoutWidth = target
            invalidateIntrinsicContentSize()
        }
    }

    public typealias UIViewType = SelfSizingLabel

    let themedAttributedString: ThemedAttributedString?
    let alignment: NSTextAlignment
    let numberOfLines: Int
    let maxWidth: CGFloat?
    let onTextTap: (@MainActor () -> Void)?
    let onImageTap: (@MainActor () -> Void)?

    /// - Parameter numberOfLines: Line cap for the wrapped `UILabel`, `0` for unlimited. SwiftUI's own
    /// `.lineLimit` reaches `Text` through the environment and so cannot cap a representable - this is the only
    /// way to limit one of these
    public init(
        _ themedAttributedString: ThemedAttributedString?,
        alignment: NSTextAlignment = .natural,
        numberOfLines: Int = 0,
        maxWidth: CGFloat? = nil,
        onTextTap: (@MainActor () -> Void)? = nil,
        onImageTap: (@MainActor () -> Void)? = nil
    ) {
        self.themedAttributedString = themedAttributedString
        self.alignment = alignment
        self.numberOfLines = numberOfLines
        self.maxWidth = maxWidth
        self.onTextTap = onTextTap
        self.onImageTap = onImageTap
    }

    public func makeUIView(context: Context) -> SelfSizingLabel {
        let label = SelfSizingLabel()
        label.explicitMaxWidth = maxWidth
        label.numberOfLines = numberOfLines
        label.themeAttributedText = themedAttributedString
        label.textAlignment = alignment
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        /// A `UILabel` given no `preferredMaxLayoutWidth` reports an intrinsic width of its whole text on one line,
        /// and at the default horizontal resistance it refuses to be squeezed below that - which widens whatever
        /// contains it rather than wrapping. Callers that know their width still pass `maxWidth`
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        label.isUserInteractionEnabled = true
        
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        label.addGestureRecognizer(tapGesture)
        
        return label
    }

    public func updateUIView(_ label: SelfSizingLabel, context: Context) {
        label.themeAttributedText = themedAttributedString
        label.numberOfLines = numberOfLines
        label.explicitMaxWidth = maxWidth
        
        if let maxWidth = maxWidth {
            label.preferredMaxLayoutWidth = maxWidth
        }
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator(
            onTextTap: onTextTap,
            onImageTap: onImageTap
        )
    }
    
    public class Coordinator: NSObject {
        let onTextTap: (@MainActor () -> Void)?
        let onImageTap: (@MainActor () -> Void)?
        
        init(
            onTextTap: (@MainActor () -> Void)?,
            onImageTap: (@MainActor () -> Void)?
        ) {
            self.onTextTap = onTextTap
            self.onImageTap = onImageTap
        }
        
        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let label = gesture.view as? UILabel else { return }
            let localPoint = gesture.location(in: label)
            if label.isPointOnAttachment(localPoint) == true {
                DispatchQueue.main.async {
                    self.onImageTap?()
                }
            } else {
                DispatchQueue.main.async {
                    self.onTextTap?()
                }
            }
        }
    }
}
