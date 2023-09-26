// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import CryptoKit
import Clibsodium
import Sodium
import Curve25519Kit

// MARK: - Singleton

public extension Singleton {
    static let crypto: SingletonConfig<CryptoType> = Dependencies.create { _ in Crypto() }
}

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
    private let sodium: Sodium = Sodium()
    
    public struct Size {
        public let id: String
        public let args: [Any?]
        let get: (Sodium) -> Int
        
        public init(id: String, args: [Any?] = [], get: @escaping (Sodium) -> Int) {
            self.id = id
            self.args = args
            self.get = get
        }
        
        public init(id: String, args: [Any?] = [], get: @escaping () -> Int) {
            self.id = id
            self.args = args
            self.get = { _ in get() }
        }
    }
    
    public struct Action {
        public let id: String
        public let args: [Any?]
        let perform: (Sodium) throws -> Array<UInt8>
        
        public init(id: String, args: [Any?] = [], perform: @escaping (Sodium) throws -> Array<UInt8>) {
            self.id = id
            self.args = args
            self.perform = perform
        }
        
        public init(id: String, args: [Any?] = [], perform: @escaping () throws -> Array<UInt8>) {
            self.id = id
            self.args = args
            self.perform = { _ in try perform() }
        }
        
        public init(id: String, args: [Any?] = [], perform: @escaping (Sodium) -> Array<UInt8>?) {
            self.id = id
            self.args = args
            self.perform = { try perform($0) ?? { throw CryptoError.failedToGenerateOutput }() }
        }
        
        public init(id: String, args: [Any?] = [], perform: @escaping () -> Array<UInt8>?) {
            self.id = id
            self.args = args
            self.perform = { _ in try perform() ?? { throw CryptoError.failedToGenerateOutput }() }
        }
    }
    
    public struct Verification {
        public let id: String
        public let args: [Any?]
        let verify: (Sodium) -> Bool
        
        public init(id: String, args: [Any?] = [], verify: @escaping (Sodium) -> Bool) {
            self.id = id
            self.args = args
            self.verify = verify
        }
        
        public init(id: String, args: [Any?] = [], verify: @escaping () -> Bool) {
            self.id = id
            self.args = args
            self.verify = { _ in verify() }
        }
    }
    
    public struct KeyPairType {
        public let id: String
        public let args: [Any?]
        let generate: (Sodium) -> KeyPair?
        
        public init(id: String, args: [Any?] = [], generate: @escaping (Sodium) -> KeyPair?) {
            self.id = id
            self.args = args
            self.generate = generate
        }
        
        public init(id: String, args: [Any?] = [], generate: @escaping () -> KeyPair?) {
            self.id = id
            self.args = args
            self.generate = { _ in generate() }
        }
    }
    
    public init() {}
    public func size(_ size: Crypto.Size) -> Int { return size.get(sodium) }
    public func perform(_ action: Crypto.Action) throws -> Array<UInt8> { return try action.perform(sodium) }
    public func verify(_ verification: Crypto.Verification) -> Bool { return verification.verify(sodium) }
    public func generate(_ keyPairType: Crypto.KeyPairType) -> KeyPair? { return keyPairType.generate(sodium) }
}
