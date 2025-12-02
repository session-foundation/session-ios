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

public final class ThemedAttributedString: @unchecked Sendable, Equatable, Hashable {
    /// `NSMutableAttributedString` is not `Sendable` so we need to manually manage access via an `NSLock` to ensure
    /// thread safety
    private let lock: NSLock = NSLock()
    private let _attributedString: NSMutableAttributedString
    
    internal var attributedString: NSAttributedString {
        lock.lock()
        defer { lock.unlock() }
        return _attributedString
    }
    
    public var string: String { attributedString.string }
    
    /// It seems that a number of UI elements don't properly check the `NSTextAttachment.accessibilityLabel` when
    /// constructing their accessibility label, as such we need to construct our own which includes that content
    public var constructedAccessibilityLabel: String {
        let result: NSMutableString = NSMutableString()
        let attrString: NSAttributedString = attributedString
        let rawString: String = attrString.string
        let fullRange: NSRange = NSRange(location: 0, length: attrString.length)
        
        attrString.enumerateAttributes(
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
    
    public init() {
        self._attributedString = NSMutableAttributedString()
    }
    
    public init(attributedString: ThemedAttributedString) {
        self._attributedString = attributedString._attributedString
    }
    
    public init(attributedString: NSAttributedString) {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attributedString)
        #endif
        self._attributedString = NSMutableAttributedString(attributedString: attributedString)
    }
    
    public init(string: String, attributes: [NSAttributedString.Key: Any] = [:]) {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attributes)
        #endif
        self._attributedString = NSMutableAttributedString(string: string, attributes: attributes)
    }
    
    public init(attachment: NSTextAttachment, attributes: [NSAttributedString.Key: Any] = [:]) {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attributes)
        #endif
        self._attributedString = NSMutableAttributedString(attachment: attachment)
    }
    
    public init(imageAttachmentGenerator: @escaping (@Sendable () -> (UIImage, String?)?), referenceFont: UIFont?) {
        self._attributedString = NSMutableAttributedString()
    }
    
    required init?(coder: NSCoder) {
        fatalError("Use init(_:attributedString:) instead")
    }
    
    public static func == (lhs: ThemedAttributedString, rhs: ThemedAttributedString) -> Bool {
        return lhs.attributedString == rhs.attributedString
    }
    
    public func hash(into hasher: inout Hasher) {
        attributedString.hash(into: &hasher)
    }
    
    // MARK: - Forwarded Functions
    
    public func attributedSubstring(from range: NSRange) -> ThemedAttributedString {
        return ThemedAttributedString(attributedString: attributedString.attributedSubstring(from: range))
    }
    
    public func insert(_ attributedString: NSAttributedString, at location: Int) {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attributedString)
        #endif
        lock.lock()
        defer { lock.unlock() }
        self._attributedString.insert(attributedString, at: location)
    }
    
    public func insert(_ other: ThemedAttributedString, at location: Int) {
        lock.lock()
        defer { lock.unlock() }
        self._attributedString.insert(other.attributedString, at: location)
    }
    
    public func appending(string: String, attributes: [NSAttributedString.Key: Any]? = nil) -> ThemedAttributedString {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attributes ?? [:])
        #endif
        lock.lock()
        defer { lock.unlock() }
        self._attributedString.append(NSAttributedString(string: string, attributes: attributes))
        return self
    }
    
    public func append(_ attributedString: NSAttributedString) {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attributedString)
        #endif
        lock.lock()
        defer { lock.unlock() }
        self._attributedString.append(attributedString)
    }
    
    public func append(_ other: ThemedAttributedString) {
        lock.lock()
        defer { lock.unlock() }
        self._attributedString.append(other.attributedString)
    }
    
    public func appending(_ attributedString: NSAttributedString) -> ThemedAttributedString {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attributedString)
        #endif
        lock.lock()
        defer { lock.unlock() }
        self._attributedString.append(attributedString)
        return self
    }
    
    public func appending(_ other: ThemedAttributedString) -> ThemedAttributedString {
        lock.lock()
        defer { lock.unlock() }
        self._attributedString.append(other.attributedString)
        return self
    }
    
    public func addAttribute(_ name: NSAttributedString.Key, value attrValue: Any, range: NSRange? = nil) {
        #if DEBUG
        ThemedAttributedString.validateAttributes([name: attributedString])
        #endif
        let targetRange: NSRange = (range ?? NSRange(location: 0, length: attributedString.length))
        lock.lock()
        defer { lock.unlock() }
        self._attributedString.addAttribute(name, value: attrValue, range: targetRange)
    }
    
    public func addingAttribute(_ name: NSAttributedString.Key, value attrValue: Any, range: NSRange? = nil) -> ThemedAttributedString {
        #if DEBUG
        ThemedAttributedString.validateAttributes([name: attributedString])
        #endif
        let targetRange: NSRange = (range ?? NSRange(location: 0, length: attributedString.length))
        lock.lock()
        defer { lock.unlock() }
        self._attributedString.addAttribute(name, value: attrValue, range: targetRange)
        return self
    }

    public func addAttributes(_ attrs: [NSAttributedString.Key: Any], range: NSRange? = nil) {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attrs)
        #endif
        let targetRange: NSRange = (range ?? NSRange(location: 0, length: attributedString.length))
        lock.lock()
        defer { lock.unlock() }
        self._attributedString.addAttributes(attrs, range: targetRange)
    }
    
    public func addingAttributes(_ attrs: [NSAttributedString.Key: Any], range: NSRange? = nil) -> ThemedAttributedString {
        #if DEBUG
        ThemedAttributedString.validateAttributes(attrs)
        #endif
        let targetRange: NSRange = (range ?? NSRange(location: 0, length: attributedString.length))
        lock.lock()
        defer { lock.unlock() }
        self._attributedString.addAttributes(attrs, range: targetRange)
        return self
    }
    
    public func boundingRect(with size: CGSize, options: NSStringDrawingOptions = [], context: NSStringDrawingContext?) -> CGRect {
        return self.attributedString.boundingRect(with: size, options: options, context: context)
    }
    
    public func replaceCharacters(in range: NSRange, with attributedString: NSAttributedString) {
        lock.lock()
        defer { lock.unlock() }
        self._attributedString.replaceCharacters(in: range, with: attributedString)
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

public extension ThemedAttributedString {
    convenience init(
        image: UIImage,
        accessibilityLabel: String?,
        font: UIFont? = nil
    ) {
        let attachment: NSTextAttachment = NSTextAttachment(image: image)
        attachment.accessibilityLabel = accessibilityLabel   /// Ensure it's still visible to accessibility inspectors
        
        if let font {
            attachment.bounds = CGRect(
                x: 0,
                y: font.capHeight / 2 - image.size.height / 2,
                width: image.size.width,
                height: image.size.height
            )
        }
        
        self.init(attachment: attachment)
    }
}
