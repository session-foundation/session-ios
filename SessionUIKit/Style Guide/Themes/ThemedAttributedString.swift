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
    internal var value: NSMutableAttributedString {
        if let (image, accessibilityLabel) = imageAttachmentGenerator?() {
            let attachment: NSTextAttachment = NSTextAttachment(image: image)
            attachment.accessibilityLabel = accessibilityLabel   /// Ensure it's still visible to accessibility inspectors
            
            if let font = imageAttachmentReferenceFont {
                attachment.bounds = CGRect(
                    x: 0,
                    y: font.capHeight / 2 - image.size.height / 2,
                    width: image.size.width,
                    height: image.size.height
                )
            }
            
            return NSMutableAttributedString(attachment: attachment)
        }
        return attributedString
    }
    public var string: String { value.string }
    public var length: Int { value.length }
    
    /// It seems that a number of UI elements don't properly check the `NSTextAttachment.accessibilityLabel` when
    /// constructing their accessibility label, as such we need to construct our own which includes that content
    public var constructedAccessibilityLabel: String {
        let result: NSMutableString = NSMutableString()
        let rawString: String = value.string
        let fullRange: NSRange = NSRange(location: 0, length: self.length)
        
        value.enumerateAttributes(
            in: fullRange,
            options: []
        ) { attributes, range, stop in
            /// If it's an `NSTextAttachment` then we should remove it
            if let attachment: NSTextAttachment = attributes[.attachment] as? NSTextAttachment {
                /// It has a custom `accessibilityLabel` so we should use that
                if let label: String = attachment.accessibilityLabel, !label.isEmpty {
                    result.append(label)
                }
                
                /// It has no label so don't add anything
            } else {
                /// It's standard text so just add it
                let textSegment: String = (rawString as NSString).substring(with: range)
                result.append(textSegment)
            }
        }
        
        return result as String
    }
    
    internal var imageAttachmentGenerator: (() -> (UIImage, String?)?)?
    internal var imageAttachmentReferenceFont: UIFont?
    internal var attributedString: NSMutableAttributedString
    
    public init() {
        self.attributedString = NSMutableAttributedString()
    }
    
    public init(attributedString: ThemedAttributedString) {
        self.attributedString = attributedString.attributedString
        self.imageAttachmentGenerator = attributedString.imageAttachmentGenerator
    }
    
    public init(attributedString: NSAttributedString) {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attributedString)
        #endif
        self.attributedString = NSMutableAttributedString(attributedString: attributedString)
    }
    
    public init(string: String, attributes: [NSAttributedString.Key: Any] = [:]) {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attributes)
        #endif
        self.attributedString = NSMutableAttributedString(string: string, attributes: attributes)
    }
    
    public init(attachment: NSTextAttachment, attributes: [NSAttributedString.Key: Any] = [:]) {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attributes)
        #endif
        self.attributedString = NSMutableAttributedString(attachment: attachment)
    }
    
    public init(imageAttachmentGenerator: @escaping (() -> (UIImage, String?)?), referenceFont: UIFont?) {
        self.attributedString = NSMutableAttributedString()
        self.imageAttachmentGenerator = imageAttachmentGenerator
        self.imageAttachmentReferenceFont = referenceFont
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
        self.attributedString.append(NSAttributedString(string: string, attributes: attributes))
        return self
    }
    
    public func append(_ attributedString: NSAttributedString) {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attributedString)
        #endif
        self.attributedString.append(attributedString)
    }
    
    public func append(_ attributedString: ThemedAttributedString) {
        self.attributedString.append(attributedString.value)
    }
    
    public func appending(_ attributedString: NSAttributedString) -> ThemedAttributedString {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attributedString)
        #endif
        self.attributedString.append(attributedString)
        return self
    }
    
    public func appending(_ attributedString: ThemedAttributedString) -> ThemedAttributedString {
        self.attributedString.append(attributedString.value)
        return self
    }
    
    public func addAttribute(_ name: NSAttributedString.Key, value attrValue: Any, range: NSRange? = nil) {
        #if DEBUG
        ThemedAttributedString.validateAttributes([name: value])
        #endif
        let targetRange: NSRange = (range ?? NSRange(location: 0, length: self.length))
        self.attributedString.addAttribute(name, value: attrValue, range: targetRange)
    }
    
    public func addingAttribute(_ name: NSAttributedString.Key, value attrValue: Any, range: NSRange? = nil) -> ThemedAttributedString {
        #if DEBUG
        ThemedAttributedString.validateAttributes([name: value])
        #endif
        let targetRange: NSRange = (range ?? NSRange(location: 0, length: self.length))
        self.attributedString.addAttribute(name, value: attrValue, range: targetRange)
        return self
    }

    public func addAttributes(_ attrs: [NSAttributedString.Key: Any], range: NSRange? = nil) {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attrs)
        #endif
        let targetRange: NSRange = (range ?? NSRange(location: 0, length: self.length))
        self.attributedString.addAttributes(attrs, range: targetRange)
    }
    
    public func addingAttributes(_ attrs: [NSAttributedString.Key: Any], range: NSRange? = nil) -> ThemedAttributedString {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attrs)
        #endif
        let targetRange: NSRange = (range ?? NSRange(location: 0, length: self.length))
        self.attributedString.addAttributes(attrs, range: targetRange)
        return self
    }
    
    public func boundingRect(with size: CGSize, options: NSStringDrawingOptions = [], context: NSStringDrawingContext?) -> CGRect {
        return self.attributedString.boundingRect(with: size, options: options, context: context)
    }
    
    public func replaceCharacters(in range: NSRange, with attributedString: NSAttributedString) {
        self.attributedString.replaceCharacters(in: range, with: attributedString)
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
