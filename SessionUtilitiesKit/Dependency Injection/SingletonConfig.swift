// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

// MARK: - Singleton

public class Singleton {}

// MARK: - SingletonConfig<S>

public class SingletonConfig<S>: Singleton {
    public let key: Int
    public let createInstance: (Dependencies) -> S

    /// `fileprivate` to hide when accessing via `dependencies[singleton: ]`
    fileprivate init(
        createInstance: @escaping (Dependencies) -> S
    ) {
        self.key = ObjectIdentifier(S.self).hashValue
        self.createInstance = createInstance
    }
}

// MARK: - Creation

public extension Dependencies {
    static func create<S>(
        createInstance: @escaping (Dependencies) -> S
    ) -> SingletonConfig<S> {
        return SingletonConfig(
            createInstance: createInstance
        )
    }
}
