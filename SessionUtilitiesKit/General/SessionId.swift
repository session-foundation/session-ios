// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium

public struct SessionId {
    public static let byteCount: Int = 33
    
    public enum Prefix: String, CaseIterable {
        case standard = "05"    // Used for identified users, open groups, etc.
        case blinded15 = "15"   // Used for authentication and participants in open groups with blinding enabled
        case blinded25 = "25"   // Used for authentication and participants in open groups with blinding enabled
        case unblinded = "00"   // Used for authentication in open groups with blinding disabled
        case group = "03"       // Used for update group conversations
        
        public init?(from stringValue: String?) {
            guard let stringValue: String = stringValue else { return nil }
            
            guard stringValue.count > 2 else {
                guard let targetPrefix: Prefix = Prefix(rawValue: stringValue) else { return nil }
                self = targetPrefix
                return
            }
            
            guard KeyPair.isValidHexEncodedPublicKey(candidate: stringValue) else { return nil }
            guard let targetPrefix: Prefix = Prefix(rawValue: String(stringValue.prefix(2))) else { return nil }
            
            self = targetPrefix
        }
    }
    
    public let prefix: Prefix
    public let publicKey: String
    
    public var hexString: String {
        return prefix.rawValue + publicKey
    }
    
    // MARK: - Initialization
    
    public init?(from idString: String?) {
        guard let idString: String = idString, idString.count > 2 else { return nil }
        guard let targetPrefix: Prefix = Prefix(from: idString) else { return nil }
        
        self.prefix = targetPrefix
        self.publicKey = idString.substring(from: 2)
    }
    
    public init(_ type: Prefix, publicKey: Bytes) {
        self.prefix = type
        self.publicKey = publicKey.map { String(format: "%02hhx", $0) }.joined()
    }
}
