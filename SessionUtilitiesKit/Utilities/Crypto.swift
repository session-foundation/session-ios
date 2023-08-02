// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import CryptoKit
import Clibsodium
import Sodium
import Curve25519Kit

// MARK: - CryptoType

public protocol CryptoType {
    func size(_ size: Crypto.Size) -> Int
    func perform(_ action: Crypto.Action) throws -> Array<UInt8>
    func verify(_ verification: Crypto.Verification) -> Bool
    func generate(_ keyPairType: Crypto.KeyPairType) -> KeyPair?
}

// MARK: - CryptoError

public enum CryptoError: LocalizedError {
    case failedToGenerateOutput

    public var errorDescription: String? {
        switch self {
            case .failedToGenerateOutput: return "Failed to generate output."
        }
    }
}

// MARK: - Crypto

public struct Crypto: CryptoType {
    public struct Size {
        public let id: String
        public let args: [Any?]
        let get: () -> Int
        
        public init(id: String, args: [Any?] = [], get: @escaping () -> Int) {
            self.id = id
            self.args = args
            self.get = get
        }
    }
    
    public struct Action {
        public let id: String
        public let args: [Any?]
        let perform: () throws -> Array<UInt8>
        
        public init(id: String, args: [Any?] = [], perform: @escaping () throws -> Array<UInt8>) {
            self.id = id
            self.args = args
            self.perform = perform
        }
        
        public init(id: String, args: [Any?] = [], perform: @escaping () -> Array<UInt8>?) {
            self.id = id
            self.args = args
            self.perform = { try perform() ?? { throw CryptoError.failedToGenerateOutput }() }
        }
    }
    
    public struct Verification {
        public let id: String
        public let args: [Any?]
        let verify: () -> Bool
        
        public init(id: String, args: [Any?] = [], verify: @escaping () -> Bool) {
            self.id = id
            self.args = args
            self.verify = verify
        }
    }
    
    public struct KeyPairType {
        public let id: String
        public let args: [Any?]
        let generate: () -> KeyPair?
        
        public init(id: String, args: [Any?] = [], generate: @escaping () -> KeyPair?) {
            self.id = id
            self.args = args
            self.generate = generate
        }
    }
    
    public init() {}
    public func size(_ size: Crypto.Size) -> Int { return size.get() }
    public func perform(_ action: Crypto.Action) throws -> Array<UInt8> { return try action.perform() }
    public func verify(_ verification: Crypto.Verification) -> Bool { return verification.verify() }
    public func generate(_ keyPairType: Crypto.KeyPairType) -> KeyPair? { return keyPairType.generate() }
}
