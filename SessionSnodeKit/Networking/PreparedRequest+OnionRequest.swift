// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

public extension HTTP.PreparedRequest {
    /// Send an onion request for the prepared data
    func send(using dependencies: Dependencies) -> AnyPublisher<(ResponseInfoType, R), Error> {
        return dependencies.network
            .send(
                .onionRequest(
                    request,
                    to: server,
                    with: publicKey,
                    timeout: timeout
                )
            )
            .decoded(with: self, using: dependencies)
            .retry(retryCount, using: dependencies)
            .handleEvents(
                receiveOutput: self.outputEventHandler,
                receiveCompletion: self.completionEventHandler,
                receiveCancel: self.cancelEventHandler
            )
            .eraseToAnyPublisher()
    }
}

public extension Optional {
    func send<R>(
        using dependencies: Dependencies
    ) -> AnyPublisher<(ResponseInfoType, R), Error> where Wrapped == HTTP.PreparedRequest<R> {
        guard let instance: Wrapped = self else {
            return Fail(error: HTTPError.invalidPreparedRequest)
                .eraseToAnyPublisher()
        }
        
        return instance.send(using: dependencies)
    }
}
