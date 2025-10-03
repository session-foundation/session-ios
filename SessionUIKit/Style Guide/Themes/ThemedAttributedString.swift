// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

// MARK: - Themed NSAttributedString.Key

public extension NSAttributedString.Key {
    internal static let themedKeys: Set<NSAttributedString.Key> = [
        .themeForegroundColor, .themeBackgroundColor, .themeStrokeColor, .themeUnderlineColor, .themeStrikethroughColor
    ]
    
    static let themeForegroundColor = NSAttributedString.Key("org.getsession.themeForegroundColor")
    static let themeBackgroundColor = NSAttributedString.Key("org.getsession.themeBackgroundColor")
    static let themeStrokeColor = NSAttributedString.Key("org.getsession.themeStrokeColor")
    static let themeUnderlineColor = NSAttributedString.Key("org.getsession.themeUnderlineColor")
    static let themeStrikethroughColor = NSAttributedString.Key("org.getsession.themeStrikethroughColor")
    
    internal var originalKey: NSAttributedString.Key? {
        switch self {
            case .themeForegroundColor: return .foregroundColor
            case .themeBackgroundColor: return .backgroundColor
            case .themeStrokeColor: return .strokeColor
            case .themeUnderlineColor: return .underlineColor
            case .themeStrikethroughColor: return .strikethroughColor
            default: return nil
        }
    }
}

// MARK: - ThemedAttributedString

public class ThemedAttributedString: Equatable, Hashable {
    internal let value: NSMutableAttributedString
    public var string: String { value.string }
    public var length: Int { value.length }
    
    public init() {
        self.value = NSMutableAttributedString()
    }
    
    public init(attributedString: ThemedAttributedString) {
        self.value = attributedString.value
    }
    
    public init(attributedString: NSAttributedString) {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attributedString)
        #endif
        self.value = NSMutableAttributedString(attributedString: attributedString)
    }
    
    public init(string: String, attributes: [NSAttributedString.Key: Any] = [:]) {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attributes)
        #endif
        self.value = NSMutableAttributedString(string: string, attributes: attributes)
    }
    
    public init(attachment: NSTextAttachment, attributes: [NSAttributedString.Key: Any] = [:]) {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attributes)
        #endif
        self.value = NSMutableAttributedString(attachment: attachment)
    }
    
    required init?(coder: NSCoder) {
        fatalError("Use init(_:attributedString:) instead")
    }
    
    public static func == (lhs: ThemedAttributedString, rhs: ThemedAttributedString) -> Bool {
        return lhs.value == rhs.value
    }
    
    public func hash(into hasher: inout Hasher) {
        value.hash(into: &hasher)
    }
    
    // MARK: - Forwarded Functions
    
    public func attributedSubstring(from range: NSRange) -> ThemedAttributedString {
        return ThemedAttributedString(attributedString: value.attributedSubstring(from: range))
    }
    
    public func appending(string: String, attributes: [NSAttributedString.Key: Any]? = nil) -> ThemedAttributedString {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attributes ?? [:])
        #endif
        value.append(NSAttributedString(string: string, attributes: attributes))
        return self
    }
    
    public func append(_ attributedString: NSAttributedString) {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attributedString)
        #endif
        value.append(attributedString)
    }
    
    public func append(_ attributedString: ThemedAttributedString) {
        value.append(attributedString.value)
    }
    
    public func appending(_ attributedString: NSAttributedString) -> ThemedAttributedString {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attributedString)
        #endif
        value.append(attributedString)
        return self
    }
    
    public func appending(_ attributedString: ThemedAttributedString) -> ThemedAttributedString {
        value.append(attributedString.value)
        return self
    }
    
    public func addAttribute(_ name: NSAttributedString.Key, value attrValue: Any, range: NSRange? = nil) {
        #if DEBUG
        ThemedAttributedString.validateAttributes([name: value])
        #endif
        let targetRange: NSRange = (range ?? NSRange(location: 0, length: self.length))
        value.addAttribute(name, value: attrValue, range: targetRange)
    }
    
    public func addingAttribute(_ name: NSAttributedString.Key, value attrValue: Any, range: NSRange? = nil) -> ThemedAttributedString {
        #if DEBUG
        ThemedAttributedString.validateAttributes([name: value])
        #endif
        let targetRange: NSRange = (range ?? NSRange(location: 0, length: self.length))
        value.addAttribute(name, value: attrValue, range: targetRange)
        return self
    }

    public func addAttributes(_ attrs: [NSAttributedString.Key: Any], range: NSRange? = nil) {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attrs)
        #endif
        let targetRange: NSRange = (range ?? NSRange(location: 0, length: self.length))
        value.addAttributes(attrs, range: targetRange)
    }
    
    public func addingAttributes(_ attrs: [NSAttributedString.Key: Any], range: NSRange? = nil) -> ThemedAttributedString {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attrs)
        #endif
        let targetRange: NSRange = (range ?? NSRange(location: 0, length: self.length))
        value.addAttributes(attrs, range: targetRange)
        return self
    }
    
    public func boundingRect(with size: CGSize, options: NSStringDrawingOptions = [], context: NSStringDrawingContext?) -> CGRect {
        return value.boundingRect(with: size, options: options, context: context)
    }
    
    public func replaceCharacters(in range: NSRange, with attributedString: NSAttributedString) {
        value.replaceCharacters(in: range, with: attributedString)
    }
    
    // MARK: - Convenience
    
    #if DEBUG
    private static func validateAttributes(_ attributes: [NSAttributedString.Key: Any]) {
        for (key, value) in attributes {
            guard
                key.originalKey == nil &&
                NSAttributedString.Key.themedKeys.contains(key) == false
            else { continue }
            
            if value is ThemeValue {
                let errorMessage = """
                FATAL ERROR in ThemedAttributedString:
                You are assigning a custom ThemeValue to a standard system attribute key.
                
                - Problem Key: '\(key.rawValue)'
                - Problem Value: \(value)
                
                You should use the custom theme key '.theme\(key.rawValue.prefix(1))\(key.rawValue.dropFirst())' instead of '.\(key.rawValue)'.
                
                Example:
                - INCORRECT: [.foregroundColor: ThemeValue.textPrimary]
                - CORRECT:   [.themeForegroundColor: ThemeValue.textPrimary]
                """
                
                fatalError(errorMessage)
            }
        }
    }
    
    private static func validateAttributes(_ attributedString: NSAttributedString) {
        let fullRange = NSRange(location: 0, length: attributedString.length)
        attributedString.enumerateAttributes(in: fullRange, options: []) { attributes, range, _ in
            validateAttributes(attributes)
        }
    }
    #endif
}
