// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

// MARK: - Singleton

public class Singleton {}

// MARK: - SingletonConfig<S>

public class SingletonConfig<S>: Singleton {
    public let identifier: String
    public let createInstance: (Dependencies, Dependencies.Key) -> S

    /// `fileprivate` to hide when accessing via `dependencies[singleton: ]`
    fileprivate init(
        identifier: String,
        createInstance: @escaping (Dependencies, Dependencies.Key) -> S
    ) {
        self.identifier = identifier
        self.createInstance = createInstance
    }
}

// MARK: - Creation

public extension Dependencies {
    static func create<S>(
        identifier: String,
        createInstance: @escaping (Dependencies, Dependencies.Key) -> S
    ) -> SingletonConfig<S> {
        return SingletonConfig(
            identifier: identifier,
            createInstance: createInstance
        )
    }
}
