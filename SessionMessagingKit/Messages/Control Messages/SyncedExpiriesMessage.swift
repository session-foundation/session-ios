// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public final class SyncedExpiriesMessage: ControlMessage {
    private enum CodingKeys: String, CodingKey {
        case conversationExpiries
    }
    
    public struct SyncedExpiry: Codable, Equatable {
        let serverHash: String
        let expirationTimestamp: Int64
    }
    
    public var conversationExpiries: [String: [SyncedExpiry]] = [:]
    
    // MARK: - Validation
    
    public override var isValid: Bool {
        guard super.isValid else { return false }
        return conversationExpiries.count > 0
    }
    
    override public var isSelfSendValid: Bool { true }
    
    // MARK: - Codable
    
    required init(from decoder: Decoder) throws {
        try super.init(from: decoder)
        
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        conversationExpiries = ((try? container.decode([String: [SyncedExpiry]].self, forKey: .conversationExpiries)) ?? [:])
    }
    
    public override func encode(to encoder: Encoder) throws {
        var container: KeyedEncodingContainer<CodingKeys> = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(conversationExpiries, forKey: .conversationExpiries)
    }
    
    // MARK: - Initialization
    
    init(conversationExpiries: [String : [SyncedExpiry]]) {
        super.init()
        self.conversationExpiries = conversationExpiries
    }
    
    // MARK: - Proto Conversion
    
    public override class func fromProto(_ proto: SNProtoContent, sender: String) -> SyncedExpiriesMessage? {
        guard let syncedExpiriesProto = proto.syncedExpiries else { return nil }
        let conversationExpiries = syncedExpiriesProto.conversationExpiries.reduce(into: [String: [SyncedExpiry]]()) {
            $0[$1.syncTarget] = $1.expiries.map { syncedExpiryProto in
                return SyncedExpiry(
                    serverHash: syncedExpiryProto.serverHash,
                    expirationTimestamp: Int64(syncedExpiryProto.expirationTimestamp)
                )
            }
        }
        
        return SyncedExpiriesMessage(conversationExpiries: conversationExpiries)
    }

    public override func toProto(_ db: Database) -> SNProtoContent? {
        let syncedExpiriesProto = SNProtoSyncedExpiries.builder()
        
        let conversationExpiriesProto = conversationExpiries.compactMap { (syncTarget, expires) in
            let syncedConversationExpiriesProto = SNProtoSyncedExpiriesSyncedConversationExpiries
                .builder(syncTarget: syncTarget)
            
            let expiresProto = expires.compactMap { syncedExpiry in
                let syncedExpiryProto = SNProtoSyncedExpiriesSyncedConversationExpiriesSyncedExpiry
                    .builder(
                        serverHash: syncedExpiry.serverHash,
                        expirationTimestamp: UInt64(syncedExpiry.expirationTimestamp)
                    )

                return try? syncedExpiryProto.build()
            }
            
            syncedConversationExpiriesProto.setExpiries(expiresProto)
            
            return try? syncedConversationExpiriesProto.build()
        }
        
        syncedExpiriesProto.setConversationExpiries(conversationExpiriesProto)
        
        let contentProto = SNProtoContent.builder()
        do {
            contentProto.setSyncedExpiries(try syncedExpiriesProto.build())
            return try contentProto.build()
        } catch {
            SNLog("Couldn't construct synced expiries proto from: \(self).")
            return nil
        }
    }

    // MARK: - Description
    
    public var description: String {
        """
        SyncedExpiriesMessage(
            conversationExpiries: \(conversationExpiries.prettifiedDescription)
        )
        """
    }
}

