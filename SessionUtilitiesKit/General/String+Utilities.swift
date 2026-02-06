// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import CoreText

public extension String {
    var bytes: [UInt8] { Array(self.utf8) }
    
    var nullIfEmpty: String? {
        guard isEmpty else { return self }
        
        return nil
    }
    
    var glyphCount: Int {
        let richText = NSAttributedString(string: self)
        let line = CTLineCreateWithAttributedString(richText)
        
        return CTLineGetGlyphCount(line)
    }
    
    var isSingleAlphabet: Bool {
        return (glyphCount == 1 && isAlphabetic)
    }
    
    var isAlphabetic: Bool {
        return !isEmpty && range(of: "[^a-zA-Z]", options: .regularExpression) == nil
    }

    var isSingleEmoji: Bool {
        return (glyphCount == 1 && containsEmoji)
    }

    var containsEmoji: Bool {
        return unicodeScalars.contains { $0.isEmoji }
    }

    var containsOnlyEmoji: Bool {
        return (
            !isEmpty &&
            !unicodeScalars.contains(where: {
                !$0.isEmoji &&
                !$0.isZeroWidthJoiner
            })
        )
    }
    
    func ranges(of substring: String, options: CompareOptions = [], locale: Locale? = nil) -> [Range<Index>] {
        var ranges: [Range<Index>] = []
        
        while
            (ranges.last.map({ $0.upperBound < self.endIndex }) ?? true),
            let range = self.range(
                of: substring,
                options: options,
                range: (ranges.last?.upperBound ?? self.startIndex)..<self.endIndex,
                locale: locale
            )
        {
            ranges.append(range)
        }
        
        return ranges
    }
    
    func appending(_ other: String?) -> String {
        guard let value: String = other else { return self }
        
        return self.appending(value)
    }
}

// MARK: - Unicode Handling

private extension CharacterSet {
    static let bidiLeftToRightIsolate: String.UTF16View.Element = 0x2066
    static let bidiRightToLeftIsolate: String.UTF16View.Element = 0x2067
    static let bidiFirstStrongIsolate: String.UTF16View.Element = 0x2068
    static let bidiLeftToRightEmbedding: String.UTF16View.Element = 0x202A
    static let bidiRightToLeftEmbedding: String.UTF16View.Element = 0x202B
    static let bidiLeftToRightOverride: String.UTF16View.Element = 0x202D
    static let bidiRightToLeftOverride: String.UTF16View.Element = 0x202E
    static let bidiPopDirectionalFormatting: String.UTF16View.Element = 0x202C
    static let bidiPopDirectionalIsolate: String.UTF16View.Element = 0x2069
    
    static let bidiControlCharacterSet: CharacterSet = {
        let bidiCodeUnits: [String.UTF16View.Element] = [
            bidiLeftToRightIsolate, bidiRightToLeftIsolate, bidiFirstStrongIsolate,
            bidiLeftToRightEmbedding, bidiRightToLeftEmbedding,
            bidiLeftToRightOverride, bidiRightToLeftOverride,
            bidiPopDirectionalFormatting, bidiPopDirectionalIsolate
        ]

        return CharacterSet(
            charactersIn: bidiCodeUnits
                .compactMap { UnicodeScalar($0) }
                .map { String($0) }
                .joined()
        )
    }()
    
    static let unsafeFilenameCharacterSet: CharacterSet = CharacterSet(charactersIn: "\u{202D}\u{202E}")

    static let nonPrintingCharacterSet: CharacterSet = {
        var result: CharacterSet = .whitespacesAndNewlines
        result.formUnion(.controlCharacters)
        result.formUnion(bidiControlCharacterSet)
        // Left-to-right and Right-to-left marks.
        result.formUnion(CharacterSet(charactersIn: "\u{200E}\u{200f}"))
        return result;
    }()
}

public extension String {
    var filteredForDisplay: String {
        self.stripped
            .filterForExcessiveDiacriticals
            .ensureBalancedBidiControlCharacters
    }
    
    var filteredFilename: String {
        self.stripped
            .filterForExcessiveDiacriticals
            .filterUnsafeFilenameCharacters
    }
    
    var stripped: String {
        // If string has no printing characters, consider it empty
        guard self.trimmingCharacters(in: .nonPrintingCharacterSet).count > 0 else {
            return ""
        }
        
        return self.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    var replacingWhitespacesWithUnderscores: String {
        let sanitizedFileNameComponents = components(separatedBy: .whitespaces)
        
        return sanitizedFileNameComponents
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }
    
    private var hasExcessiveDiacriticals: Bool {
        for char in self.enumerated() {
            let scalarCount = String(char.element).unicodeScalars.count
            if scalarCount > 8 {
                return true
            }
        }

        return false
    }
    
    private var filterForExcessiveDiacriticals: String {
        guard hasExcessiveDiacriticals else { return self }
        
        return self.folding(options: .diacriticInsensitive, locale: .current)
    }
    
    private var ensureBalancedBidiControlCharacters: String {
        var isolateStartsCount: Int = 0
        var isolatePopCount: Int = 0
        var formattingStartsCount: Int = 0
        var formattingPopCount: Int = 0

        self.utf16.forEach { char in
            switch char {
                case CharacterSet.bidiLeftToRightIsolate, CharacterSet.bidiRightToLeftIsolate,
                    CharacterSet.bidiFirstStrongIsolate:
                    isolateStartsCount += 1
                    
                case CharacterSet.bidiPopDirectionalIsolate: isolatePopCount += 1

                case CharacterSet.bidiLeftToRightEmbedding, CharacterSet.bidiRightToLeftEmbedding,
                    CharacterSet.bidiLeftToRightOverride, CharacterSet.bidiRightToLeftOverride:
                    formattingStartsCount += 1
                
                case CharacterSet.bidiPopDirectionalFormatting: formattingPopCount += 1
                
                default: break
            }
        }
        
        var balancedString: String = ""
        
        func charStr(_ utf16: String.UTF16View.Element) -> String {
            return String(UnicodeScalar(utf16)!)
        }
        
        // If we have too many isolate pops, prepend FSI to balance
        while isolatePopCount > isolateStartsCount {
            balancedString.append(charStr(CharacterSet.bidiFirstStrongIsolate))
            isolateStartsCount += 1
        }
        
        // If we have too many formatting pops, prepend LRE to balance
        while formattingPopCount > formattingStartsCount {
            balancedString.append(charStr(CharacterSet.bidiLeftToRightEmbedding))
            formattingStartsCount += 1
        }
        
        balancedString.append(self)
        
        // If we have too many formatting starts, append PDF to balance
        while formattingStartsCount > formattingPopCount {
            balancedString.append(charStr(CharacterSet.bidiPopDirectionalFormatting))
            formattingPopCount += 1
        }
        
        // If we have too many isolate starts, append PDI to balance
        while isolateStartsCount > isolatePopCount {
            balancedString.append(charStr(CharacterSet.bidiPopDirectionalIsolate))
            isolatePopCount += 1
        }
        
        return balancedString
    }
    
    private var filterUnsafeFilenameCharacters: String {
        let unsafeCharacterSet: CharacterSet = CharacterSet.unsafeFilenameCharacterSet
        
        guard self.rangeOfCharacter(from: unsafeCharacterSet) != nil else { return self }
        
        var filtered = ""
        var remainder = self
        
        while let range = remainder.rangeOfCharacter(from: unsafeCharacterSet) {
            if range.lowerBound != remainder.startIndex {
                filtered += remainder[..<range.lowerBound]
            }
            // The "replacement" code point.
            filtered += "\u{FFFD}"
            remainder = String(remainder[range.upperBound...])
        }
        filtered += remainder
        return filtered
    }
}
