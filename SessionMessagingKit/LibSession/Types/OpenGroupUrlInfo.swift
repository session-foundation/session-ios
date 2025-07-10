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
        
        public static func fetchOne(_ db: ObservingDatabase, id: String) throws -> OpenGroupUrlInfo? {
            return try OpenGroup
                .filter(id: id)
                .select(.threadId, .server, .roomToken, .publicKey)
                .asRequest(of: OpenGroupUrlInfo.self)
                .fetchOne(db)
        }
        
        public static func fetchAll(_ db: ObservingDatabase, ids: [String]) throws -> [OpenGroupUrlInfo] {
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
        
        // MARK: - Initialization
        
        init(
            urlInfo: OpenGroupUrlInfo,
            capabilities: Set<Capability.Variant>
        ) {
            self.urlInfo = urlInfo
            self.capabilities = capabilities
        }
        
        public init(
            roomToken: String,
            server: String,
            publicKey: String,
            capabilities: Set<Capability.Variant>
        ) {
            self.urlInfo = OpenGroupUrlInfo(
                threadId: OpenGroup.idFor(roomToken: roomToken, server: server),
                server: server,
                roomToken: roomToken,
                publicKey: publicKey
            )
            self.capabilities = capabilities
        }
        
        // MARK: - Queries
        
        public static func fetchOne(_ db: ObservingDatabase, server: String, activeOnly: Bool = true) throws -> OpenGroupCapabilityInfo? {
            var query: QueryInterfaceRequest<OpenGroupUrlInfo> = OpenGroup
                .select(.threadId, .server, .roomToken, .publicKey)
                .filter(OpenGroup.Columns.server == server.lowercased())
                .asRequest(of: OpenGroupUrlInfo.self)
            
            /// If we only want to retrieve data for active OpenGroups then add additional filters
            if activeOnly {
                query = query
                    .filter(OpenGroup.Columns.isActive == true)
                    .filter(OpenGroup.Columns.roomToken != "")
            }
            
            guard let urlInfo: OpenGroupUrlInfo = try query.fetchOne(db) else { return nil }
            
            let capabilities: Set<Capability.Variant> = (try? Capability
                .select(.variant)
                .filter(Capability.Columns.openGroupServer == urlInfo.server.lowercased())
                .filter(Capability.Columns.isMissing == false)
                .asRequest(of: Capability.Variant.self)
                .fetchSet(db))
                .defaulting(to: [])
            
            return OpenGroupCapabilityInfo(
                urlInfo: urlInfo,
                capabilities: capabilities
            )
        }
        
        public static func fetchOne(_ db: ObservingDatabase, id: String) throws -> OpenGroupCapabilityInfo? {
            let maybeUrlInfo: OpenGroupUrlInfo? = try OpenGroup
                .filter(id: id)
                .select(.threadId, .server, .roomToken, .publicKey)
                .asRequest(of: OpenGroupUrlInfo.self)
                .fetchOne(db)
            
            guard let urlInfo: OpenGroupUrlInfo = maybeUrlInfo else { return nil }
            
            let capabilities: Set<Capability.Variant> = (try? Capability
                .select(.variant)
                .filter(Capability.Columns.openGroupServer == urlInfo.server.lowercased())
                .filter(Capability.Columns.isMissing == false)
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
