// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct AttributedLabel: UIViewRepresentable {
    public typealias UIViewType = UILabel

    let themedAttributedString: ThemedAttributedString?
    let alignment: NSTextAlignment
    let maxWidth: CGFloat?
    let onTextTap: (@MainActor () -> Void)?
    let onImageTap: (@MainActor () -> Void)?

    public init(
        _ themedAttributedString: ThemedAttributedString?,
        alignment: NSTextAlignment = .natural,
        maxWidth: CGFloat? = nil,
        onTextTap: (@MainActor () -> Void)? = nil,
        onImageTap: (@MainActor () -> Void)? = nil
    ) {
        self.themedAttributedString = themedAttributedString
        self.alignment = alignment
        self.maxWidth = maxWidth
        self.onTextTap = onTextTap
        self.onImageTap = onImageTap
    }

    public func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.themeAttributedText = themedAttributedString
        label.textAlignment = alignment
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .vertical)
        label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        label.isUserInteractionEnabled = true
        
        let tapGesture = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap))
        label.addGestureRecognizer(tapGesture)
        
        return label
    }

    public func updateUIView(_ label: UILabel, context: Context) {
        label.themeAttributedText = themedAttributedString
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
