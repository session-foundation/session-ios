// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public struct SessionId: Equatable, Hashable, CustomStringConvertible {
    public static let byteCount: Int = 33
    public static let invalid: SessionId = SessionId(.standard, publicKey: [])
    
    public enum Prefix: String, CaseIterable, Hashable {
        case standard = "05"    // Used for identified users, open groups, etc.
        case blinded15 = "15"   // Used for authentication and participants in open groups with blinding enabled
        case blinded25 = "25"   // Used for authentication and participants in open groups with blinding enabled
        case unblinded = "00"   // Used for authentication in open groups with blinding disabled
        case group = "03"       // Used for update group conversations
        
        public init(from stringValue: String?) throws {
            guard let stringValue: String = stringValue else { throw SessionIdError.emptyValue }
            
            switch Prefix(rawValue: String(stringValue.prefix(2))) {
                case _ where stringValue.count < 2: throw SessionIdError.invalidLength
                case .none: throw SessionIdError.invalidPrefix
                case .some(let prefix) where stringValue.count == 2: self = prefix
                case .some(let prefix) where stringValue.count > 2:
                    guard KeyPair.isValidHexEncodedPublicKey(candidate: stringValue) else {
                        throw SessionIdError.invalidSessionId
                    }
                    
                    self = prefix
                    
                case .some: throw SessionIdError.invalidSessionId   // Should be covered by above cases
            }
        }
        
        /// In SQLite it's more efficient to check if an indexed column is `{column} > '05' AND {column} < '06'` then it is to use
        /// a wildcard like`{column} LIKE '05%'` as the wildcard can't use the index, so this variable is here to streamline this behaviour
        ///
        /// stringlint:ignore_contents
        public var endOfRangeString: String {
            switch self {
                case .standard: return "06"
                case .blinded15: return "16"
                case .blinded25: return "26"
                case .unblinded: return "01"
                case .group: return "04"
            }
        }
    }
    
    public let prefix: Prefix
    public let publicKey: [UInt8]
    public let publicKeyString: String
    
    public var hexString: String {
        return prefix.rawValue + publicKeyString
    }
    
    // MARK: - Initialization
    
    /// Takes a `String` and returns a valid `SessionId` or throws if empty/invalid
    public init(from idString: String?) throws {
        guard let idString: String = idString, idString.count > 2 else { throw SessionIdError.invalidSessionId }
        
        self.prefix = try Prefix(from: idString)
        self.publicKey = Array(Data(hex: idString.substring(from: 2)))
        self.publicKeyString = idString.substring(from: 2)
    }
    
    /// Takes a specified `Prefix` and `publicKey` bytes and assumes the provided values are correct
    ///
    /// **Note:** This will remove any `Prefix` from the `publicKey` and use the provided one instead
    public init(_ type: Prefix, publicKey: [UInt8]) {
        self.prefix = type
        
        // If there was a prefix on the `publicKey` then remove it
        let hexString: String = publicKey.toHexString()
        
        switch (publicKey.count, try? SessionId.Prefix(from: hexString)) {
            case (SessionId.byteCount, .some):
                self.publicKey = Array(publicKey.suffix(SessionId.byteCount - 1))
                self.publicKeyString = Array(publicKey.suffix(SessionId.byteCount - 1)).toHexString()
                
            default:
                self.publicKey = publicKey
                self.publicKeyString = hexString
        }
    }
    
    /// Takes a specified `Prefix` and `publicKey` string and assumes the provided values are correct
    ///
    /// **Note:** This will remove any `Prefix` from the `hex` and use the provided one instead
    public init(_ type: Prefix, hex: String) {
        self.prefix = type
        
        // If there was a prefix on the `hex` then remove it
        switch (hex.count, try? SessionId.Prefix(from: hex)) {
            // Multiply the `byteCount` by 2 because there are 2 characters for each byte in hex
            case ((SessionId.byteCount * 2), .some):
                self.publicKey = Array(Data(hex: String(hex.suffix(((SessionId.byteCount - 1) * 2)))))
                self.publicKeyString = String(hex.suffix(((SessionId.byteCount - 1) * 2)))
                
            default:
                self.publicKey = Array(Data(hex: hex))
                self.publicKeyString = hex
        }
    }
    
    // MARK: - CustomStringConvertible
    
    public var description: String { hexString }
}

// MARK: - SessionIdError

public enum SessionIdError: Error, CustomStringConvertible {
    case emptyValue
    case invalidLength
    case invalidPrefix
    case invalidSessionId
    
    // stringlint:ignore_contents
    public var description: String {
        switch self {
            case .emptyValue: return "The provided Account ID was empty."
            case .invalidLength: return "The provided Account ID was the wrong length."
            case .invalidPrefix: return "The provided Account ID has the wrong prefix."
            case .invalidSessionId: return "The provided Account ID was invalid."
        }
    }
}
