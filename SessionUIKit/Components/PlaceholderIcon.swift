// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import UIKit
import CryptoKit

public enum PlaceholderIcon {
    private static let colors: [UIColor] = Theme.PrimaryColor.allCases.map { $0.color }
    
    // stringlint:ignore_contents
    public static func generate(seed: String, text: String, size: CGFloat) -> UIImage {
        let content: (intSeed: Int, initials: String) = content(seed: seed, text: text)

        /// **Important:** This is frequently called from a background thread (image loading happens off the main thread via
        /// `ImageDataManager`), so this **must not** create or mutate any `CALayer`/`UIView`. Doing so opens an implicit
        /// `CATransaction` on the background thread which is later committed when that thread is torn down, running Auto Layout
        /// off the main thread and triggering the `CoreAutoLayout: _AssertAutoLayoutOnAllowedThreadsOnly` crash (historically
        /// the #1 crash). Drawing directly into the `UIGraphicsImageRenderer` context with Core Graphics + text drawing is
        /// thread-safe and creates no layers.
        let diameter: CGFloat = size
        let initials: String = content.initials
        let color: UIColor = PlaceholderIcon.colors[content.intSeed % PlaceholderIcon.colors.count]
        let font: UIFont = UIFont.boldSystemFont(ofSize: (diameter / 2))

        let paragraphStyle: NSMutableParagraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,    /// Intentionally avoid the theme system to avoid threading issues
            .paragraphStyle: paragraphStyle
        ]
        let attributedText: NSAttributedString = NSAttributedString(string: initials, attributes: attributes)
        let textHeight: CGFloat = attributedText
            .boundingRect(
                with: CGSize(width: diameter, height: .greatestFiniteMagnitude),
                options: .usesLineFragmentOrigin,
                context: nil
            )
            .height

        /// Use an explicit scale so we don't need to touch `UIScreen` (a main-thread-only API) from a background thread
        let format: UIGraphicsImageRendererFormat = UIGraphicsImageRendererFormat()
        format.scale = (SNUIKit.initialMainScreenScale ?? 1)
        format.opaque = false

        let renderer: UIGraphicsImageRenderer = UIGraphicsImageRenderer(
            size: CGSize(width: diameter, height: diameter),
            format: format
        )

        return renderer.image { context in
            /// Background fill (the containing `ProfilePictureView` applies any corner rounding)
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: diameter, height: diameter))

            /// Vertically centred initials (matches the previous `CATextLayer` layout)
            attributedText.draw(
                with: CGRect(x: 0, y: ((diameter - textHeight) / 2), width: diameter, height: textHeight),
                options: .usesLineFragmentOrigin,
                context: nil
            )
        }
    }
    
    // MARK: - Internal
    
    internal static func content(seed: String, text: String) -> (intSeed: Int, initials: String) {
        let intSeed: Int = {
            var hash = seed
            
            if (hash.matches("^[0-9A-Fa-f]+$") && hash.count >= 12) {
                // This is the same as the `SessionUtilitiesKit` `toHexString` function
                hash = Data(SHA512.hash(data: Data(Array(seed.utf8))).makeIterator())
                    .map { String(format: "%02x", $0) }.joined()
            }
            
            return (Int(String(hash.prefix(12)), radix: 16) ?? 0)
        }()
        
        var content: String = {
            guard text.hasSuffix("\(String(seed.suffix(4))))") else {
                guard let result: String = text.split(separator: "(").first.map({ String($0) }) else {
                    return text
                }
                
                return result
            }
            
            return text
        }()

        if ValidSessionIdPrefixes.hasValidPrefix(content) {
            content.removeFirst(2)
        }
        
        let initials: String = content
            .split(separator: " ")
            .compactMap { word in word.first.map { String($0) } }
            .joined()
        
        return (
            intSeed,
            (initials.count >= 2 ?
                String(initials.prefix(2)).uppercased() :
                String(content.prefix(2)).uppercased()
            )
        )
    }
    
}

private extension String {
    func matches(_ regex: String) -> Bool {
        return self.range(of: regex, options: .regularExpression, range: nil, locale: nil) != nil
    }
}

/// These enums should always match the `SessionUtilitiesKit.SessionId.Prefix` cases
private enum ValidSessionIdPrefixes: String, CaseIterable {
    case standard = "05"
    case blinded15 = "15"
    case blinded25 = "25"
    case unblinded = "00"
    case group = "03"
    
    static func hasValidPrefix(_ value: String) -> Bool {
        return value.count >= 2 && allCases.map({ $0.rawValue }).contains(String(value.prefix(2)))
    }
}
