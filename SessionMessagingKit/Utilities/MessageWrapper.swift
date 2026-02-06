// stringlint:disable

import Foundation
import SessionNetworkingKit
import SessionUtilitiesKit

public enum MessageWrapperError: Error, CustomStringConvertible {
    case failedToUnwrapData(Error, Network.SnodeAPI.Namespace)

    public var description: String {
        switch self {
            case .failedToUnwrapData(let error, let namespace):
                return "Failed to unwrap data from '\(namespace)' namespace due to error: \(error)."
        }
    }
}

public enum MessageWrapper {

    /// - Note: `data` shouldn't be base 64 encoded.
    public static func unwrap(
        data: Data,
        namespace: Network.SnodeAPI.Namespace,
        includesWebSocketMessage: Bool = true
    ) throws -> SNProtoEnvelope {
        do {
            let envelopeData: Data = try {
                guard includesWebSocketMessage else { return data }
                
                let webSocketMessage = try WebSocketProtoWebSocketMessage.parseData(data)
                return webSocketMessage.request!.body!
            }()
            return try SNProtoEnvelope.parseData(envelopeData)
        } catch let error {
            throw MessageWrapperError.failedToUnwrapData(error, namespace)
        }
    }
}
