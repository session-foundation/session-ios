// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import CryptoKit
import Clibsodium
import Sodium
import Curve25519Kit

// MARK: - Singleton

public extension Singleton {
    static let crypto: SingletonConfig<CryptoType> = Dependencies.create(
        identifier: "crypto",
        createInstance: { _ in Crypto() }
    )
}

// MARK: - CryptoType

public protocol CryptoType {
    func size(_ size: Crypto.Size) -> Int
    func generate<R>(_ generator: Crypto.Generator<R>) -> R?
    func tryGenerate<R>(_ generator: Crypto.Generator<R>) throws -> R
    func verify(_ verification: Crypto.Verification) -> Bool
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
    
    public struct Generator<T> {
        public let id: String
        public let args: [Any?]
        let generate: (Sodium) throws -> T
        
        public init(id: String, args: [Any?] = [], generate: @escaping (Sodium) throws -> T) {
            self.id = id
            self.args = args
            self.generate = generate
        }
        
        public init(id: String, args: [Any?] = [], generate: @escaping () throws -> T) {
            self.id = id
            self.args = args
            self.generate = { _ in try generate() }
        }
        
        public init(id: String, args: [Any?] = [], generate: @escaping (Sodium) -> T?) {
            self.id = id
            self.args = args
            self.generate = { try generate($0) ?? { throw CryptoError.failedToGenerateOutput }() }
        }
        
        public init(id: String, args: [Any?] = [], generate: @escaping () -> T?) {
            self.id = id
            self.args = args
            self.generate = { _ in try generate() ?? { throw CryptoError.failedToGenerateOutput }() }
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
    
    public init() {}
    public func size(_ size: Crypto.Size) -> Int { return size.get(sodium) }
    public func generate<R>(_ generator: Crypto.Generator<R>) -> R? { return try? generator.generate(sodium) }
    public func tryGenerate<R>(_ generator: Crypto.Generator<R>) throws -> R { return try generator.generate(sodium) }
    public func verify(_ verification: Crypto.Verification) -> Bool { return verification.verify(sodium) }
}
