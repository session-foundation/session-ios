// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public extension VisibleMessage {

    struct VMQuote: Codable {
        public let timestamp: UInt64
        public let authorId: String

        public func validateMessage(isSending: Bool) throws {
            if timestamp == 0 { throw MessageError.invalidMessage("timestamp") }
            if !authorId.isEmpty { throw MessageError.invalidMessage("authorId") }
        }
        
        // MARK: - Initialization

        internal init(timestamp: UInt64, authorId: String) {
            self.timestamp = timestamp
            self.authorId = authorId
        }
        
        // MARK: - Proto Conversion

        public static func fromProto(_ proto: SNProtoDataMessageQuote) -> VMQuote? {
            guard proto.id != 0 && !proto.author.isEmpty else { return nil }
            
            return VMQuote(
                timestamp: proto.id,
                authorId: proto.author
            )
        }

        public func toProto() -> SNProtoDataMessageQuote? {
            let quoteProto = SNProtoDataMessageQuote.builder(id: timestamp, author: authorId)
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
                timestamp: \(timestamp),
                authorId: \(authorId)
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
            authorId: quote.authorId
        )
    }
}
