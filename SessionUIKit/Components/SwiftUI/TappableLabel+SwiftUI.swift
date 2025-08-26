// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI
import UIKit

// FIXME: This is a hack because it is not feasible for the background of @You in SwiftUI

public struct TappableLabel_SwiftUI: UIViewRepresentable {
    let themeAttributedText: ThemedAttributedString?
    let maxWidth: CGFloat
    
    public init(
        themeAttributedText: ThemedAttributedString?,
        maxWidth: CGFloat
    ) {
        self.themeAttributedText = themeAttributedText
        self.maxWidth = maxWidth
    }
    
    public func makeUIView(context: Context) -> Container {
        let result: TappableLabel = TappableLabel()
        result.setContentHuggingPriority(.required, for: .horizontal)
        result.setContentHuggingPriority(.required, for: .vertical)
        result.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        result.themeAttributedText = themeAttributedText
        result.themeBackgroundColor = .clear
        result.isOpaque = false
        result.isUserInteractionEnabled = true
        
        return Container(label: result, maxWidth: maxWidth)
    }
    
    public func updateUIView(_ container: Container, context: Context) {
        container.label.themeAttributedText = themeAttributedText
        container.maxWidth = maxWidth
        container.invalidateIntrinsicContentSize()
        container.setNeedsLayout()
        container.layoutIfNeeded()
    }
    
    public final class Container: UIView {
        let label: TappableLabel
        var maxWidth: CGFloat
        private var widthCap: NSLayoutConstraint?
        
        init(label: TappableLabel, maxWidth: CGFloat) {
            self.label = label
            self.maxWidth = maxWidth
            super.init(frame: .zero)
            
            addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: topAnchor),
                label.leadingAnchor.constraint(equalTo: leadingAnchor),
                label.trailingAnchor.constraint(equalTo: trailingAnchor),
                label.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            
            setContentHuggingPriority(.required, for: .horizontal)
            setContentCompressionResistancePriority(.required, for: .horizontal)
            setContentHuggingPriority(.required, for: .vertical)
            setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }
        
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        
        public override func layoutSubviews() {
            super.layoutSubviews()
            
            // Use the actual size SwiftUI assigned after .frame(maxHeight:)
            let assignedWidth = min(bounds.width, maxWidth)
            let assignedHeight = bounds.height
            
            // Make UILabel compute multi-line correctly
            label.preferredMaxLayoutWidth = assignedWidth
            
            // Keep label’s internal text container width in sync for taps/highlights
            label.textContainer.size = CGSize(width: assignedWidth, height: assignedHeight > 0 ? assignedHeight : .greatestFiniteMagnitude)
            
            // Decide truncation based on the final assigned height
            guard let text = label.attributedText, text.length > 0, assignedWidth > 0 else { return }
            
            let info = layoutInfo(for: text, width: assignedWidth) // unlimited lines at this width
            let total = info.totalHeight
            
            if assignedHeight > 0 && assignedHeight + 0.5 < total {
                // Height is capped → compute how many lines fit and truncate tail
                let linesFit = max(1, fittedLineCount(fromBottoms: info.lineBottoms, cap: assignedHeight))
                if label.numberOfLines != linesFit || label.lineBreakMode != .byTruncatingTail {
                    label.numberOfLines = linesFit
                    label.lineBreakMode = .byTruncatingTail
                }
            } else {
                // No cap or content fits → unlimited wrapping
                if label.numberOfLines != 0 || label.lineBreakMode != .byWordWrapping {
                    label.numberOfLines = 0
                    label.lineBreakMode = .byWordWrapping
                }
            }
        }
        
        public override var intrinsicContentSize: CGSize {
            guard let text = label.attributedText, text.length > 0 else {
                return label.intrinsicContentSize
            }
            // Hug natural (single-line) width if it fits; else wrap to maxWidth
            let natural = measure(text, constrainedToWidth: nil)
            if natural.width <= maxWidth {
                return natural
            } else {
                let wrapped = measure(text, constrainedToWidth: maxWidth)
                return CGSize(width: maxWidth, height: wrapped.height)
            }
        }
        
        public override func sizeThatFits(_ size: CGSize) -> CGSize {
            // Respect a smaller proposed width (e.g., inside tight parents)
            let cap = min(size.width > 0 ? size.width : .greatestFiniteMagnitude, maxWidth)
            guard let text = label.attributedText, text.length > 0 else {
                return label.sizeThatFits(CGSize(width: cap, height: .greatestFiniteMagnitude))
            }
            let natural = measure(text, constrainedToWidth: nil)
            if natural.width <= cap {
                return natural
            } else {
                let wrapped = measure(text, constrainedToWidth: cap)
                return CGSize(width: cap, height: wrapped.height)
            }
        }
        
        private func fittedLineCount(fromBottoms bottoms: [CGFloat], cap: CGFloat) -> Int {
            var count = 0
            for b in bottoms {
                if b <= cap { count += 1 } else { break }
            }
            return count
        }
        
        /// Unlimited-lines measurement + per-line bottoms at a given width.
        private func layoutInfo(for text: NSAttributedString, width: CGFloat) -> (totalHeight: CGFloat, lineBottoms: [CGFloat]) {
            let storage = NSTextStorage(attributedString: text)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            container.lineBreakMode = .byWordWrapping
            container.maximumNumberOfLines = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            
            _ = layout.glyphRange(for: container)
            
            var lineBottoms: [CGFloat] = []
            var glyphIndex = 0
            while glyphIndex < layout.numberOfGlyphs {
                var lineRange = NSRange(location: 0, length: 0)
                let frag = layout.lineFragmentUsedRect(forGlyphAt: glyphIndex,
                                                       effectiveRange: &lineRange,
                                                       withoutAdditionalLayout: true)
                lineBottoms.append(ceil(frag.maxY))
                glyphIndex = NSMaxRange(lineRange)
            }
            
            let used = layout.usedRect(for: container)
            return (totalHeight: ceil(used.height), lineBottoms: lineBottoms)
        }
        
        // Kept for intrinsicContentSize / width-hugging path
        private func measure(_ text: NSAttributedString, constrainedToWidth width: CGFloat?) -> CGSize {
            let storage = NSTextStorage(attributedString: text)
            let layout = NSLayoutManager()
            let container = NSTextContainer(size: CGSize(width: width ?? .greatestFiniteMagnitude,
                                                         height: .greatestFiniteMagnitude))
            container.lineFragmentPadding = 0
            container.lineBreakMode = label.lineBreakMode
            container.maximumNumberOfLines = 0
            layout.addTextContainer(container)
            storage.addLayoutManager(layout)
            
            _ = layout.glyphRange(for: container)
            let used = layout.usedRect(for: container)
            // ceil to avoid fractional clipping
            return CGSize(width: ceil(used.width), height: ceil(used.height))
        }
    }
}
