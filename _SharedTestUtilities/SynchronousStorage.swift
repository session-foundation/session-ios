// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import SessionUtilitiesKit

class SynchronousStorage: Storage {
    override func readPublisher<S, T>(
        receiveOn scheduler: S,
        value: @escaping (Database) throws -> T
    ) -> AnyPublisher<T, Error> where S: Scheduler {
        guard let result: T = super.read(value) else {
            return Fail(error: StorageError.generic)
                .eraseToAnyPublisher()
        }
        
        return Just(result)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
    
    override func writePublisher<S, T>(
        receiveOn scheduler: S,
        updates: @escaping (Database) throws -> T
    ) -> AnyPublisher<T, Error> where S: Scheduler {
        guard let result: T = super.write(updates: updates) else {
            return Fail(error: StorageError.generic)
                .eraseToAnyPublisher()
        }
        
        return Just(result)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
}
