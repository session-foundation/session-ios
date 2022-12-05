// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtilitiesKit

class SynchronousStorage: Storage {
    override func writePublisher<T>(updates: @escaping (Database) throws -> T) -> AnyPublisher<T, Error> {
        guard let result: T = super.write(updates: updates) else {
            return Fail(error: StorageError.generic)
                .eraseToAnyPublisher()
        }
        
        return Just(result)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
}
