// stringlint:disable

import Foundation
import SessionSnodeKit
import SessionUtilitiesKit

public enum MessageWrapper {

    public enum Error : LocalizedError {
        case failedToWrapData
        case failedToWrapMessageInEnvelope
        case failedToWrapEnvelopeInWebSocketMessage
        case failedToUnwrapData

        public var errorDescription: String? {
            switch self {
            case .failedToWrapData: return "Failed to wrap data."
            case .failedToWrapMessageInEnvelope: return "Failed to wrap message in envelope."
            case .failedToWrapEnvelopeInWebSocketMessage: return "Failed to wrap envelope in web socket message."
            case .failedToUnwrapData: return "Failed to unwrap data."
            }
        }
    }

    /// Wraps the given parameters in an `SNProtoEnvelope` and then a `WebSocketProtoWebSocketMessage` to match the desktop application.
    public static func wrap(
        type: SNProtoEnvelope.SNProtoEnvelopeType,
        timestampMs: UInt64,
        senderPublicKey: String = "",   // FIXME: Remove once legacy groups are deprecated
        content: Data,
        wrapInWebSocketMessage: Bool = true
    ) throws -> Data {
        do {
            let envelope: SNProtoEnvelope = try createEnvelope(
                type: type,
                timestamp: timestampMs,
                senderPublicKey: senderPublicKey,
                content: content
            )
            
            // If we don't want to wrap the message within the `WebSocketProtoWebSocketMessage` type
            // the just serialise and return here
            guard wrapInWebSocketMessage else { return try envelope.serializedData() }
            
            // Otherwise add the additional wrapper
            let webSocketMessage = try createWebSocketMessage(around: envelope)
            return try webSocketMessage.serializedData()
        } catch let error {
            throw error as? Error ?? Error.failedToWrapData
        }
    }

    private static func createEnvelope(type: SNProtoEnvelope.SNProtoEnvelopeType, timestamp: UInt64, senderPublicKey: String, content: Data) throws -> SNProtoEnvelope {
        do {
            let builder = SNProtoEnvelope.builder(type: type, timestamp: timestamp)
            builder.setSource(senderPublicKey)
            builder.setSourceDevice(1)
            builder.setContent(content)
            return try builder.build()
        } catch let error {
            SNLog("Failed to wrap message in envelope: \(error).")
            throw Error.failedToWrapMessageInEnvelope
        }
    }

    private static func createWebSocketMessage(around envelope: SNProtoEnvelope) throws -> WebSocketProtoWebSocketMessage {
        do {
            let requestBuilder = WebSocketProtoWebSocketRequestMessage.builder(verb: "", path: "", requestID: 0)
            requestBuilder.setBody(try envelope.serializedData())
            let messageBuilder = WebSocketProtoWebSocketMessage.builder(type: .request)
            messageBuilder.setRequest(try requestBuilder.build())
            return try messageBuilder.build()
        } catch let error {
            SNLog("Failed to wrap envelope in web socket message: \(error).")
            throw Error.failedToWrapEnvelopeInWebSocketMessage
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
            SNLog("Failed to unwrap data: \(error).")
            throw Error.failedToUnwrapData
        }
    }
}
