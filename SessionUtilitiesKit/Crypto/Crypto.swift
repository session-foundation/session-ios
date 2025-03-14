// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

// MARK: - Singleton

public extension Singleton {
    static let crypto: SingletonConfig<CryptoType> = Dependencies.create(
        identifier: "crypto",
        createInstance: { dependencies in Crypto(using: dependencies) }
    )
}

// MARK: - CryptoType

public protocol CryptoType {
    func tryGenerate<R>(_ generator: Crypto.Generator<R>) throws -> R
    func verify(_ verification: Crypto.Verification) -> Bool
}

public extension CryptoType {
    func generate<R>(_ generator: Crypto.Generator<R>) -> R? {
        return try? tryGenerate(generator)
    }
    
    func generateResult<R>(_ generator: Crypto.Generator<R>) -> Result<R, Error> {
        return Result(try tryGenerate(generator))
    }
}

// MARK: - Crypto

public struct Crypto: CryptoType {
    public struct Generator<T> {
        public let id: String
        public let args: [Any?]
        fileprivate let generate: (Dependencies) throws -> T
        
        public init(id: String, args: [Any?] = [], generate: @escaping () throws -> T) {
            self.id = id
            self.args = args
            self.generate = { _ in try generate() }
        }
        
        public init(id: String, args: [Any?] = [], generate: @escaping (Dependencies) throws -> T) {
            self.id = id
            self.args = args
            self.generate = generate
        }
    }
    
    public struct Verification {
        public let id: String
        public let args: [Any?]
        let verify: (Dependencies) -> Bool
        
        public init(id: String, args: [Any?] = [], verify: @escaping () -> Bool) {
            self.id = id
            self.args = args
            self.verify = { _ in verify() }
        }
        
        public init(id: String, args: [Any?] = [], verify: @escaping (Dependencies) -> Bool) {
            self.id = id
            self.args = args
            self.verify = verify
        }
    }
    
    // MARK: - Initialization
    
    public let dependencies: Dependencies
    
    public init(using dependencies: Dependencies) {
        self.dependencies = dependencies
    }
    
    // MARK: - Functions
    
    public func tryGenerate<R>(_ generator: Crypto.Generator<R>) throws -> R {
        return try generator.generate(dependencies)
    }
    
    public func verify(_ verification: Crypto.Verification) -> Bool {
        return verification.verify(dependencies)
    }
}
