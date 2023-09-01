// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

// MARK: - Singleton

public class Singleton {}

// MARK: - SingletonInfo

public enum SingletonInfo {
    public class Config<S>: Singleton {
        public let key: Int
        public let createInstance: (Dependencies) -> S

        fileprivate init(
            createInstance: @escaping (Dependencies) -> S
        ) {
            self.key = ObjectIdentifier(S.self).hashValue
            self.createInstance = createInstance
        }
    }
}

public extension SingletonInfo {
    static func create<S>(
        createInstance: @escaping (Dependencies) -> S
    ) -> SingletonInfo.Config<S> {
        return SingletonInfo.Config(
            createInstance: createInstance
        )
    }
}
