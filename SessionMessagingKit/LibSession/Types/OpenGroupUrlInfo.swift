// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public extension LibSession {
    // MARK: - OpenGroupUrlInfo
    
    struct OpenGroupUrlInfo: FetchableRecord, Codable, Hashable {
        let threadId: String
        let server: String
        let roomToken: String
        let publicKey: String
        
        // MARK: - Queries
        
        public static func fetchOne(_ db: Database, id: String) throws -> OpenGroupUrlInfo? {
            return try OpenGroup
                .filter(id: id)
                .select(.threadId, .server, .roomToken, .publicKey)
                .asRequest(of: OpenGroupUrlInfo.self)
                .fetchOne(db)
        }
        
        public static func fetchAll(_ db: Database, ids: [String]) throws -> [OpenGroupUrlInfo] {
            return try OpenGroup
                .filter(ids: ids)
                .select(.threadId, .server, .roomToken, .publicKey)
                .asRequest(of: OpenGroupUrlInfo.self)
                .fetchAll(db)
        }
    }
    
    // MARK: - OpenGroupCapabilityInfo
    
    struct OpenGroupCapabilityInfo: FetchableRecord, Codable, Hashable {
        private let urlInfo: OpenGroupUrlInfo
        
        var threadId: String { urlInfo.threadId }
        var server: String { urlInfo.server }
        var roomToken: String { urlInfo.roomToken }
        var publicKey: String { urlInfo.publicKey }
        let capabilities: Set<Capability.Variant>
        
        // MARK: - Queries
        
        public static func fetchOne(_ db: Database, id: String) throws -> OpenGroupCapabilityInfo? {
            let maybeUrlInfo: OpenGroupUrlInfo? = try OpenGroup
                .filter(id: id)
                .select(.threadId, .server, .roomToken, .publicKey)
                .asRequest(of: OpenGroupUrlInfo.self)
                .fetchOne(db)
            
            guard let urlInfo: OpenGroupUrlInfo = maybeUrlInfo else { return nil }
            
            let capabilities: Set<Capability.Variant> = (try? Capability
                .select(.variant)
                .filter(Capability.Columns.openGroupServer == urlInfo.server.lowercased())
                .asRequest(of: Capability.Variant.self)
                .fetchSet(db))
                .defaulting(to: [])
            
            return OpenGroupCapabilityInfo(
                urlInfo: urlInfo,
                capabilities: capabilities
            )
        }
    }
}
