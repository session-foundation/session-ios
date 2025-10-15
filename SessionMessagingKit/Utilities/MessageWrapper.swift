// stringlint:disable

import Foundation
import SessionNetworkingKit
import SessionUtilitiesKit

public enum MessageWrapper {

    public enum Error : LocalizedError {
        case failedToUnwrapData

        public var errorDescription: String? {
            switch self {
            case .failedToUnwrapData: return "Failed to unwrap data."
            }
        }
    }

    /// - Note: `data` shouldn't be base 64 encoded.
    public static func unwrap(
        data: Data,
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
            Log.error(.messageSender, "Failed to unwrap data: \(error).")
            throw Error.failedToUnwrapData
        }
    }
}
