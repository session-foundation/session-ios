// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

// MARK: - Themed NSAttributedString.Key

public extension NSAttributedString.Key {
    internal static let themedKeys: Set<NSAttributedString.Key> = [
        .themeForegroundColor, .themeBackgroundColor, .themeStrokeColor, .themeUnderlineColor
    ]
    
    static let themeForegroundColor = NSAttributedString.Key("org.getsession.themeForegroundColor")
    static let themeBackgroundColor = NSAttributedString.Key("org.getsession.themeBackgroundColor")
    static let themeStrokeColor = NSAttributedString.Key("org.getsession.themeStrokeColor")
    static let themeUnderlineColor = NSAttributedString.Key("org.getsession.themeUnderlineColor")
    
    internal var originalKey: NSAttributedString.Key? {
        switch self {
            case .themeForegroundColor: return .foregroundColor
            case .themeBackgroundColor: return .themeBackgroundColor
            case .themeStrokeColor: return .strokeColor
            case .themeUnderlineColor: return .underlineColor
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
        self.value = NSMutableAttributedString(attributedString: attributedString)
    }
    
    public init(string: String, attributes: [NSAttributedString.Key: Any] = [:]) {
        self.value = NSMutableAttributedString(string: string, attributes: attributes)
    }
    
    public init(attachment: NSTextAttachment, attributes: [NSAttributedString.Key: Any] = [:]) {
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
        value.append(NSAttributedString(string: string, attributes: attributes))
        return self
    }
    
    public func append(_ attributedString: NSAttributedString) {
        value.append(attributedString)
    }
    
    public func append(_ attributedString: ThemedAttributedString) {
        value.append(attributedString.value)
    }
    
    public func appending(_ attributedString: NSAttributedString) -> ThemedAttributedString {
        value.append(attributedString)
        return self
    }
    
    public func appending(_ attributedString: ThemedAttributedString) -> ThemedAttributedString {
        value.append(attributedString.value)
        return self
    }
    
    public func addAttribute(_ name: NSAttributedString.Key, value attrValue: Any, range: NSRange) {
        value.addAttribute(name, value: attrValue, range: range)
    }
    
    public func addAttributes(_ attrs: [NSAttributedString.Key: Any], range: NSRange) {
        value.addAttributes(attrs, range: range)
    }
    
    public func boundingRect(with size: CGSize, options: NSStringDrawingOptions = [], context: NSStringDrawingContext?) -> CGRect {
        return value.boundingRect(with: size, options: options, context: context)
    }
}
