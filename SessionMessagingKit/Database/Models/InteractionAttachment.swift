// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public struct InteractionAttachment: Sendable, Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "interactionAttachment" }
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case albumIndex
        case interactionId
        case attachmentId
    }
    
    public let albumIndex: Int
    public let interactionId: Int64
    public let attachmentId: String
    
    // MARK: - Initialization
    
    public init(
        albumIndex: Int,
        interactionId: Int64,
        attachmentId: String
    ) {
        self.albumIndex = albumIndex
        self.interactionId = interactionId
        self.attachmentId = attachmentId
    }
}
