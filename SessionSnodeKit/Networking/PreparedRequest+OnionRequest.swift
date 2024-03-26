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
                        return dependencies.network
                            .send(
                                .onionRequest(
                                    request,
                                    to: serverTarget.server,
                                    endpoint: serverTarget.rawEndpoint,
                                    with: serverTarget.x25519PublicKey,
                                    timeout: timeout
                                ),
                                using: dependencies
                            )
                        
                    case let snodeTarget as HTTP.SnodeTarget:
                        guard let payload: Data = request.httpBody else { throw SnodeAPIError.invalidPreparedRequest }

                        return dependencies.network
                            .send(
                                .onionRequest(
                                    payload,
                                    to: snodeTarget.snode,
                                    associatedWith: snodeTarget.associatedPublicKey,
                                    timeout: timeout
                                ),
                                using: dependencies
                            )
                        
                    case let randomSnode as HTTP.RandomSnodeTarget:
                        guard let payload: Data = request.httpBody else { throw SnodeAPIError.invalidPreparedRequest }

                        return SnodeAPI.getSwarm(for: randomSnode.publicKey, using: dependencies)
                            .tryFlatMapWithRandomSnode(retry: SnodeAPI.maxRetryCount, using: dependencies) { snode in
                                dependencies.network
                                    .send(
                                        .onionRequest(
                                            payload,
                                            to: snode,
                                            associatedWith: randomSnode.publicKey,
                                            timeout: timeout
                                        ),
                                        using: dependencies
                                    )
                            }
                        
                    case let randomSnode as HTTP.RandomSnodeLatestNetworkTimeTarget:
                        guard request.httpBody != nil else { throw SnodeAPIError.invalidPreparedRequest }
                        
                        return SnodeAPI.getSwarm(for: randomSnode.publicKey, using: dependencies)
                            .tryFlatMapWithRandomSnode(retry: SnodeAPI.maxRetryCount, using: dependencies) { snode in
                                try SnodeAPI
                                    .getNetworkTime(from: snode, using: dependencies)
                                    .tryFlatMap { timestampMs in
                                        guard
                                            let updatedRequest: URLRequest = try? randomSnode
                                                .urlRequestWithUpdatedTimestampMs(timestampMs, dependencies),
                                            let payload: Data = updatedRequest.httpBody
                                        else { throw SnodeAPIError.invalidPreparedRequest }
                                        
                                        return dependencies.network
                                            .send(
                                                .onionRequest(
                                                    payload,
                                                    to: snode,
                                                    associatedWith: randomSnode.publicKey,
                                                    timeout: timeout
                                                ),
                                                using: dependencies
                                            )
                                            .map { info, response -> (ResponseInfoType, Data?) in
                                                (
                                                    SnodeAPI.LatestTimestampResponseInfo(
                                                        code: info.code,
                                                        headers: info.headers,
                                                        timestampMs: timestampMs
                                                    ),
                                                    response
                                                )
                                            }
                                    }
                            }
                        
                    default: throw SnodeAPIError.invalidPreparedRequest
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
            return Fail(error: SnodeAPIError.invalidPreparedRequest)
                .eraseToAnyPublisher()
        }
        
        return instance.send(using: dependencies)
    }
}
