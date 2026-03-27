// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import SessionUtilitiesKit

public extension Network.PreparedRequest {
    func send(using dependencies: Dependencies) async throws -> (info: ResponseInfoType, value: R) {
        /// Need to calculate a `finalRetryCount` to ensure the request is sent at least once
        var lastError: Error?
        let finalRetryCount: Int = (retryCount < 0 ? 1 : retryCount + 1)
        
        for _ in 0..<finalRetryCount {
            do {
                let response: (info: ResponseInfoType, value: Data?) = try await dependencies[singleton: .network].send(
                    endpoint: endpoint,
                    destination: destination,
                    body: body,
                    category: category,
                    requestTimeout: requestTimeout,
                    overallTimeout: overallTimeout
                )
                let result: (originalData: Any, convertedData: R) = try self.decode(info: response.info, data: response.value, using: dependencies)
                self.postSendAction?()
                
                return (response.info, result.convertedData)
            }
            catch {
                lastError = error
            }
        }
        
        throw lastError ?? NetworkError.invalidResponse
    }
}

public extension Network.PreparedRequest {
    func send(using dependencies: Dependencies) async throws -> R {
        return try await send(using: dependencies).value
    }
}
