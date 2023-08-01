// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Combine
import GRDB
import SessionUtilitiesKit

class SynchronousStorage: Storage {
    override func readPublisher<T>(
        value: @escaping (Database) throws -> T
    ) -> AnyPublisher<T, Error> {
        guard let result: T = super.read(value) else {
            return Fail(error: StorageError.generic)
                .eraseToAnyPublisher()
        }
        
        return Just(result)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
    
    override func writePublisher<T>(
        fileName: String = #file,
        functionName: String = #function,
        lineNumber: Int = #line,
        updates: @escaping (Database) throws -> T
    ) -> AnyPublisher<T, Error> {
        guard let result: T = super.write(fileName: fileName, functionName: functionName, lineNumber: lineNumber, updates: updates) else {
            return Fail(error: StorageError.generic)
                .eraseToAnyPublisher()
        }
        
        return Just(result)
            .setFailureType(to: Error.self)
            .eraseToAnyPublisher()
    }
}
