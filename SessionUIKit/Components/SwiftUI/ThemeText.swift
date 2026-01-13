// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import SwiftUI

public struct ThemedText: View {
    private let segments: [ThemedTextSegment]
    @ObservedObject private var observer = ThemeObserver.shared
    
    #if DEBUG
    @Environment(\.previewTheme) private var previewTheme
    #endif
    
    public init(_ text: Text) { self.segments = [ThemedTextSegment(text: text)] }
    public init(_ content: LocalizedStringKey) { self.segments = [ThemedTextSegment(text: Text(content))] }
    public init<S>(_ content: S) where S: StringProtocol {
        self.segments = [ThemedTextSegment(text: Text(content))]
    }
    
    internal init(blocks: [AttributedTextBlock]) {
        self.segments = blocks.map { block in
            var text = Text(block.content)
            
            if let font = block.font { text = text.font(font) }
            if let color = block.color { text = text.foregroundColor(color) }
            if let baselineOffset = block.baselineOffset { text = text.baselineOffset(baselineOffset) }
            
            return ThemedTextSegment(
                text: text,
                foregroundThemeColor: block.foregroundThemeColor,
                underlineThemeColor: block.underlineThemeColor,
                strikethroughThemeColor: block.strikethroughThemeColor
            )
        }
    }
    
    private init(segments: [ThemedTextSegment]) {
        self.segments = segments
    }
    
    public var body: some View {
        var targetTheme: Theme = observer.theme
        var targetPrimaryColor: Theme.PrimaryColor = observer.primaryColor
        
        #if DEBUG
        if let (theme, primaryColor) = previewTheme {
            targetTheme = theme
            targetPrimaryColor = primaryColor
        }
        #endif
        
        return segments.reduce(Text("")) { result, segment in
            result + segment.resolved(theme: targetTheme, primaryColor: targetPrimaryColor)
        }
    }
    
    // MARK: - Convenience Functions
    
    private func applySingleSegmentModifier(_ transform: (ThemedTextSegment) -> ThemedTextSegment) -> ThemedText {
        guard segments.count == 1 else { return self }
        
        return ThemedText(segments: [transform(segments[0])])
    }
    
    private func applyTextTransform(_ transform: @escaping (Text) -> Text) -> ThemedText {
        applySingleSegmentModifier { $0.applying(transform) }
    }

}

// MARK: - ThemedTextSegment

private struct ThemedTextSegment {
    let text: Text
    let foregroundThemeColor: ThemeValue?
    let underlineThemeColor: ThemeValue?
    let strikethroughThemeColor: ThemeValue?
    
    init(
        text: Text,
        foregroundThemeColor: ThemeValue? = nil,
        underlineThemeColor: ThemeValue? = nil,
        strikethroughThemeColor: ThemeValue? = nil
    ) {
        self.text = text
        self.foregroundThemeColor = foregroundThemeColor
        self.underlineThemeColor = underlineThemeColor
        self.strikethroughThemeColor = strikethroughThemeColor
    }
    
    func resolved(theme: Theme, primaryColor: Theme.PrimaryColor) -> Text {
        var result = text
        
        if
            let value: ThemeValue = foregroundThemeColor,
            let color: Color = ThemeManager.color(for: value, in: theme, with: primaryColor)
        {
            result = result.foregroundColor(color)
        }
        
        if
            let value: ThemeValue = underlineThemeColor,
            let color: Color = ThemeManager.color(for: value, in: theme, with: primaryColor)
        {
            result = result.underline(color: color)
        }
        
        if
            let value: ThemeValue = strikethroughThemeColor,
            let color: Color = ThemeManager.color(for: value, in: theme, with: primaryColor)
        {
            result = result.strikethrough(color: color)
        }
        
        return result
    }
    
    func applying(_ transform: (Text) -> Text) -> ThemedTextSegment {
        ThemedTextSegment(
            text: transform(text),
            foregroundThemeColor: foregroundThemeColor,
            underlineThemeColor: underlineThemeColor,
            strikethroughThemeColor: strikethroughThemeColor
        )
    }
}


// MARK: - Theme Modifiers

public extension ThemedText {
    func foregroundColor(themeColor: ThemeValue) -> ThemedText {
        applySingleSegmentModifier { segment in
            ThemedTextSegment(
                text: segment.text,
                foregroundThemeColor: themeColor,
                underlineThemeColor: segment.underlineThemeColor,
                strikethroughThemeColor: segment.strikethroughThemeColor
            )
        }
    }
    
    func underlineColor(themeColor: ThemeValue) -> ThemedText {
        applySingleSegmentModifier { segment in
            ThemedTextSegment(
                text: segment.text,
                foregroundThemeColor: segment.foregroundThemeColor,
                underlineThemeColor: themeColor,
                strikethroughThemeColor: segment.strikethroughThemeColor
            )
        }
    }
    
    func strikethroughColor(themeColor: ThemeValue) -> ThemedText {
        applySingleSegmentModifier { segment in
            ThemedTextSegment(
                text: segment.text,
                foregroundThemeColor: segment.foregroundThemeColor,
                underlineThemeColor: segment.underlineThemeColor,
                strikethroughThemeColor: themeColor
            )
        }
    }
}

// MARK: - Standard Modifiers

public extension ThemedText {
    func font(_ font: Font?) -> ThemedText {
        applyTextTransform { $0.font(font) }
    }
    
    func fontWeight(_ weight: Font.Weight?) -> ThemedText {
        applyTextTransform { $0.fontWeight(weight) }
    }
    
    func bold() -> ThemedText {
        applyTextTransform { $0.bold() }
    }
    
    func italic() -> ThemedText {
        applyTextTransform { $0.italic() }
    }
    
    func underline(_ active: Bool = true, color: Color? = nil) -> ThemedText {
        applyTextTransform { $0.underline(active, color: color) }
    }
    
    func strikethrough(_ active: Bool = true, color: Color? = nil) -> ThemedText {
        applyTextTransform { $0.strikethrough(active, color: color) }
    }
    
    func baselineOffset(_ baselineOffset: CGFloat) -> ThemedText {
        applyTextTransform { $0.baselineOffset(baselineOffset) }
    }
    
    func foregroundColor(_ color: Color?) -> ThemedText {
        applyTextTransform { $0.foregroundColor(color) }
    }
}

// MARK: - Concatenation

public extension ThemedText {
    static func + (lhs: ThemedText, rhs: ThemedText) -> ThemedText {
        ThemedText(segments: lhs.segments + rhs.segments)
    }
    
    static func + (lhs: ThemedText, rhs: Text) -> ThemedText {
        ThemedText(segments: lhs.segments + [ThemedTextSegment(text: rhs)])
    }
    
    static func + (lhs: Text, rhs: ThemedText) -> ThemedText {
        ThemedText(segments: [ThemedTextSegment(text: lhs)] + rhs.segments)
    }
}

// MARK: - Convenience

public extension Text {
    func themed() -> ThemedText {
        return ThemedText(self)
    }
}
