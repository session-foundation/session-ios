// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum Hex {
    public static func isValid(_ string: String) -> Bool {
        let allowedCharacters = CharacterSet(charactersIn: "0123456789ABCDEF")
        
        return string.uppercased().unicodeScalars.allSatisfy { allowedCharacters.contains($0) }
    }
}

// MARK: - Data

public extension Data {
    var bytes: [UInt8] { return Array(self) }
    
    func toHexString() -> String {
        return bytes.toHexString()
    }
    
    init(hex: String) {
        self.init(Array<UInt8>(hex: hex))
    }
}

// MARK: - Array

public extension Array where Element == UInt8 {
    init(hex: String) {
        self = Array<Element>()
        self.reserveCapacity(hex.unicodeScalars.lazy.underestimatedCount)
        
        var buffer: UInt8?
        var skip = (hex.hasPrefix("0x") ? 2 : 0)
          
        for char in hex.unicodeScalars.lazy {
            guard skip == 0 else {
                skip -= 1
                continue
            }
            
            guard char.value >= 48 && char.value <= 102 else {
                removeAll()
                return
            }
        
            let v: UInt8
            let c: UInt8 = UInt8(char.value)
            
            switch c {
                case let c where c <= 57: v = c - 48
                case let c where c >= 65 && c <= 70: v = c - 55
                case let c where c >= 97: v = c - 87
                  
                default:
                    removeAll()
                    return
            }
            
            if let b = buffer {
                append(b << 4 | v)
                buffer = nil
            }
            else {
                buffer = v
            }
        }
        
        if let b = buffer {
            append(b)
        }
    }
    
    func toHexString() -> String {
        return map { String(format: "%02x", $0) }.joined()
    }

    func toBase64(options: Data.Base64EncodingOptions = []) -> String {
        Data(self).base64EncodedString(options: options)
    }
}
