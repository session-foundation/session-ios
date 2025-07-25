// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

struct AttributedTextBlock {
    let content: String
    let font: Font?
    let color: Color?
    let baselineOffset: CGFloat?
}

public struct AttributedText: View {
    var attributedText: ThemedAttributedString?
    
    private var descriptions: [AttributedTextBlock] = []
    
    public init(_ attributedText: ThemedAttributedString?) {
        self.attributedText = attributedText
        
        self.extractDescriptions()
    }
    public init(_ attributedText: NSAttributedString) {
        self.init(ThemedAttributedString(attributedString: attributedText))
    }
    
    private mutating func extractDescriptions()  {
        if let text = attributedText?.value {
            text.enumerateAttributes(in: NSMakeRange(0, text.length), options: [], using: { (attribute, range, stop) in
                let substring = (text.string as NSString).substring(with: range)
                let font = (attribute[.font] as? UIFont).map { Font($0) }
                let color = (
                    (attribute[.themeForegroundColor] as? ThemeValue).map { Color($0) } ??
                    (attribute[.foregroundColor] as? UIColor).map { Color($0) }
                )
                let baselineOffset = (attribute[.baselineOffset] as? CGFloat)
                descriptions.append(
                    AttributedTextBlock(
                        content: substring,
                        font: font,
                        color: color,
                        baselineOffset: baselineOffset
                    )
                )
            })
        }
    }
    
    public var body: some View {
        descriptions.map { description in
            var text: Text = Text(description.content)
            if let font: Font = description.font { text = text.font(font) }
            if let color: Color = description.color { text = text.foregroundColor(color) }
            if let baselineOffset: CGFloat = description.baselineOffset { text = text.baselineOffset(baselineOffset) }
            return text
        }.reduce(Text("")) { (result, text) in
            result + text
        }
    }
}
