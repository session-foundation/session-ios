// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

struct AttributedTextBlock {
    let content: String
    let font: Font?
    let color: Color?
    let foregroundThemeColor: ThemeValue?
    let underlineThemeColor: ThemeValue?
    let strikethroughThemeColor: ThemeValue?
    let baselineOffset: CGFloat?
    let currentUserMentionBackground: (color: ThemeValue?, cornerRadius: CGFloat?, padding: CGFloat?)
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
    
    private mutating func extractDescriptions() {
        if let text = attributedText?.value {
            text.enumerateAttributes(in: NSMakeRange(0, text.length), options: [], using: { (attribute, range, stop) in
                let substring = (text.string as NSString).substring(with: range)
                let font = (attribute[.font] as? UIFont).map { Font($0) }
                let color = (attribute[.foregroundColor] as? UIColor).map { Color($0) }
                let foregroundThemeColor = (attribute[.themeForegroundColor] as? ThemeValue)
                let underlineThemeColor = (attribute[.themeUnderlineColor] as? ThemeValue)
                let strikethroughThemeColor = (attribute[.themeStrikethroughColor] as? ThemeValue)
                let baselineOffset = (attribute[.baselineOffset] as? CGFloat)
                let currentUserMentionBackground = (
                    color: attribute[.currentUserMentionBackgroundColor] as? ThemeValue,
                    cornerRadius: attribute[.currentUserMentionBackgroundCornerRadius] as? CGFloat,
                    padding: attribute[.currentUserMentionBackgroundPadding] as? CGFloat
                )
                descriptions.append(
                    AttributedTextBlock(
                        content: substring,
                        font: font,
                        color: color,
                        foregroundThemeColor: foregroundThemeColor,
                        underlineThemeColor: underlineThemeColor,
                        strikethroughThemeColor: strikethroughThemeColor,
                        baselineOffset: baselineOffset,
                        currentUserMentionBackground: currentUserMentionBackground
                    )
                )
            })
        }
    }
    
    public var body: some View {
        if descriptions.isEmpty {
            return ThemedText("")
        }
        else {
            return ThemedText(blocks: descriptions)
        }
    }
}
