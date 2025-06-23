// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension VisibleMessage {

    struct VMQuote: Codable {
        public let timestamp: UInt64?
        public let authorId: String?
        public let text: String?

        public func isValid(isSending: Bool) -> Bool { timestamp != nil && authorId != nil }
        
        // MARK: - Initialization

        internal init(timestamp: UInt64, authorId: String, text: String?) {
            self.timestamp = timestamp
            self.authorId = authorId
            self.text = text
        }
        
        // MARK: - Proto Conversion

        public static func fromProto(_ proto: SNProtoDataMessageQuote) -> VMQuote? {
            return VMQuote(
                timestamp: proto.id,
                authorId: proto.author,
                text: proto.text
            )
        }

        public func toProto() -> SNProtoDataMessageQuote? {
            guard let timestamp = timestamp, let authorId = authorId else {
                Log.warn(.messageSender, "Couldn't construct quote proto from: \(self).")
                return nil
            }
            let quoteProto = SNProtoDataMessageQuote.builder(id: timestamp, author: authorId)
            if let text = text { quoteProto.setText(text) }
            do {
                return try quoteProto.build()
            } catch {
                Log.warn(.messageSender, "Couldn't construct quote proto from: \(self).")
                return nil
            }
        }
        
        // MARK: - Description
        
        public var description: String {
            """
            Quote(
                timestamp: \(timestamp?.description ?? "null"),
                authorId: \(authorId ?? "null"),
                text: \(text ?? "null")
            )
            """
        }
    }
}

// MARK: - Database Type Conversion

public extension VisibleMessage.VMQuote {
    static func from(quote: Quote) -> VisibleMessage.VMQuote {
        return VisibleMessage.VMQuote(
            timestamp: UInt64(quote.timestampMs),
            authorId: quote.authorId,
            text: quote.body
        )
    }
}
