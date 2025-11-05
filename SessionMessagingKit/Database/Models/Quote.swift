// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public struct Quote: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "quote" }
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case interactionId
        case authorId
        case timestampMs
    }
    
    /// The id for the interaction this Quote belongs to
    public let interactionId: Int64
    
    /// The id for the author this Quote belongs to
    public let authorId: String
    
    /// The timestamp in milliseconds since epoch when the quoted interaction was sent
    public let timestampMs: Int64
    
    // MARK: - Interaction
    
    public init(
        interactionId: Int64,
        authorId: String,
        timestampMs: Int64
    ) {
        self.interactionId = interactionId
        self.authorId = authorId
        self.timestampMs = timestampMs
    }
}

// MARK: - Mutation

public extension Quote {
    func with(
        interactionId: Int64? = nil,
        authorId: String? = nil,
        timestampMs: Int64? = nil
    ) -> Quote {
        return Quote(
            interactionId: interactionId ?? self.interactionId,
            authorId: authorId ?? self.authorId,
            timestampMs: timestampMs ?? self.timestampMs
        )
    }
    
    func withOriginalMessageDeleted() -> Quote {
        return Quote(
            interactionId: self.interactionId,
            authorId: self.authorId,
            timestampMs: self.timestampMs
        )
    }
}
