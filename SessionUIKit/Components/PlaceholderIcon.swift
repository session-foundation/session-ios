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
        let layer = generateLayer(
            with: size,
            text: content.initials,
            seed: content.intSeed
        )
        
        let rect = CGRect(origin: CGPoint.zero, size: layer.frame.size)
        let renderer = UIGraphicsImageRenderer(size: rect.size)
        
        return renderer.image { layer.render(in: $0.cgContext) }
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
    
    private static func generateLayer(with diameter: CGFloat, text: String, seed: Int) -> CALayer {
        let color: UIColor = PlaceholderIcon.colors[seed % PlaceholderIcon.colors.count]
        let font = UIFont.boldSystemFont(ofSize: diameter / 2)
        let height = NSString(string: text).boundingRect(with: CGSize(width: diameter, height: CGFloat.greatestFiniteMagnitude),
            options: .usesLineFragmentOrigin, attributes: [ NSAttributedString.Key.font : font ], context: nil).height
        let frame = CGRect(x: 0, y: (diameter - height) / 2, width: diameter, height: height)
        
        let layer = CATextLayer()
        layer.frame = frame
        layer.foregroundColor = UIColor.white.cgColor   /// Intentionally avoid theme system to avoid threading issues
        layer.contentsScale = UIScreen.main.scale
        
        let fontName = font.fontName
        let fontRef = CGFont(fontName as CFString)
        layer.font = fontRef
        layer.fontSize = font.pointSize
        layer.alignmentMode = .center
        layer.string = text
        
        let base = CALayer()
        base.frame = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        base.masksToBounds = true
        base.backgroundColor = color.cgColor            /// Intentionally avoid theme system to avoid threading issues
        base.addSublayer(layer)
        
        return base
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
