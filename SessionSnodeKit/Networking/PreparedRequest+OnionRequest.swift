// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

public extension HTTP.PreparedRequest {
    /// Send an onion request for the prepared data
    func send(using dependencies: Dependencies) -> AnyPublisher<(ResponseInfoType, R), Error> {
        // If we have a cached response then user that directly
        if let cachedResponse: HTTP.PreparedRequest<R>.CachedResponse = self.cachedResponse {
            return Just(cachedResponse)
                .setFailureType(to: Error.self)
                .handleEvents(
                    receiveSubscription: { _ in self.subscriptionHandler?() },
                    receiveOutput: self.outputEventHandler,
                    receiveCompletion: self.completionEventHandler,
                    receiveCancel: self.cancelEventHandler
                )
                .eraseToAnyPublisher()
        }
        
        // Otherwise trigger the request
        return Just(())
            .setFailureType(to: Error.self)
            .tryFlatMap { _ in
                switch target {
                    case let serverTarget as any ServerRequestTarget:
                        return dependencies[singleton: .network]
                            .send(
                                .onionRequest(
                                    request,
                                    to: serverTarget.server,
                                    with: serverTarget.x25519PublicKey,
                                    timeout: timeout
                                )
                            )
                        
                    case let randomSnode as HTTP.RandomSnodeTarget:
                        guard let payload: Data = request.httpBody else { throw HTTPError.invalidPreparedRequest }
                        
                        return SnodeAPI.getSwarm(for: randomSnode.publicKey, using: dependencies)
                            .tryFlatMapWithRandomSnode(retry: SnodeAPI.maxRetryCount) { snode in
                                dependencies[singleton: .network]
                                    .send(
                                        .onionRequest(
                                            payload,
                                            to: snode,
                                            timeout: timeout
                                        )
                                    )
                            }
                        
                    default: throw HTTPError.invalidPreparedRequest
                }
            }
            .decoded(with: self, using: dependencies)
            .retry(retryCount, using: dependencies)
            .handleEvents(
                receiveSubscription: { _ in self.subscriptionHandler?() },
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
