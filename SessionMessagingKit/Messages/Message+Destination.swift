// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

public extension Message {
    enum Destination: Codable {
        case contact(
            publicKey: String,
            namespace: SnodeAPI.Namespace
        )
        case closedGroup(
            groupPublicKey: String,
            namespace: SnodeAPI.Namespace
        )
        case openGroup(
            roomToken: String,
            server: String,
            whisperTo: String? = nil,
            whisperMods: Bool = false,
            fileIds: [String]? = nil
        )
        case openGroupInbox(server: String, openGroupPublicKey: String, blindedPublicKey: String)

        static func from(
            _ db: Database,
            thread: SessionThread,
            fileIds: [String]? = nil
        ) throws -> Message.Destination {
            switch thread.variant {
                case .contact:
                    if SessionId.Prefix(from: thread.id) == .blinded {
                        guard let lookup: BlindedIdLookup = try? BlindedIdLookup.fetchOne(db, id: thread.id) else {
                            preconditionFailure("Attempting to send message to blinded id without the Open Group information")
                        }
                        
                        return .openGroupInbox(
                            server: lookup.openGroupServer,
                            openGroupPublicKey: lookup.openGroupPublicKey,
                            blindedPublicKey: thread.id
                        )
                    }
                    
                    return .contact(publicKey: thread.id, namespace: .default)
                
                case .closedGroup:
                    return .closedGroup(groupPublicKey: thread.id, namespace: .legacyClosedGroup)
                
                case .openGroup:
                    guard let openGroup: OpenGroup = try thread.openGroup.fetchOne(db) else {
                        throw StorageError.objectNotFound
                    }
                    
                    return .openGroup(roomToken: openGroup.roomToken, server: openGroup.server, fileIds: fileIds)
            }
        }
        
        func with(fileIds: [String]) -> Message.Destination {
            // Only Open Group messages support receiving the 'fileIds'
            switch self {
                case .openGroup(let roomToken, let server, let whisperTo, let whisperMods, _):
                    return .openGroup(
                        roomToken: roomToken,
                        server: server,
                        whisperTo: whisperTo,
                        whisperMods: whisperMods,
                        fileIds: fileIds
                    )
                    
                default: return self
            }
        }
        
        // MARK: - Codable
        
        // FIXME: Remove this custom implementation after enough time has passed (added the 'namespace' properties)
        public init(from decoder: Decoder) throws {
            let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
            
            // Should only have a single root key so we can just switch on it to have cleaner code
            switch container.allKeys.first {
                case .contact:
                    let childContainer: KeyedDecodingContainer<ContactCodingKeys> = try container.nestedContainer(keyedBy: ContactCodingKeys.self, forKey: .contact)
                    
                    self = .contact(
                        publicKey: try childContainer.decode(String.self, forKey: .publicKey),
                        namespace: (
                            (try? childContainer.decode(SnodeAPI.Namespace.self, forKey: .namespace)) ??
                            .default
                        )
                    )
                    
                case .closedGroup:
                    let childContainer: KeyedDecodingContainer<ClosedGroupCodingKeys> = try container.nestedContainer(keyedBy: ClosedGroupCodingKeys.self, forKey: .closedGroup)
                    
                    self = .closedGroup(
                        groupPublicKey: try childContainer.decode(String.self, forKey: .groupPublicKey),
                        namespace: (
                            (try? childContainer.decode(SnodeAPI.Namespace.self, forKey: .namespace)) ??
                            .legacyClosedGroup
                        )
                    )
                    
                case .openGroup:
                    let childContainer: KeyedDecodingContainer<OpenGroupCodingKeys> = try container.nestedContainer(keyedBy: OpenGroupCodingKeys.self, forKey: .openGroup)
                    
                    self = .openGroup(
                        roomToken: try childContainer.decode(String.self, forKey: .roomToken),
                        server: try childContainer.decode(String.self, forKey: .server),
                        whisperTo: try? childContainer.decode(String.self, forKey: .whisperTo),
                        whisperMods: try childContainer.decode(Bool.self, forKey: .whisperMods),
                        fileIds: try? childContainer.decode([String].self, forKey: .fileIds)
                    )
                
                case .openGroupInbox:
                    let childContainer: KeyedDecodingContainer<OpenGroupInboxCodingKeys> = try container.nestedContainer(keyedBy: OpenGroupInboxCodingKeys.self, forKey: .openGroupInbox)
                    
                    self = .openGroupInbox(
                        server: try childContainer.decode(String.self, forKey: .server),
                        openGroupPublicKey: try childContainer.decode(String.self, forKey: .openGroupPublicKey),
                        blindedPublicKey: try childContainer.decode(String.self, forKey: .blindedPublicKey)
                    )
                    
                default: throw MessageReceiverError.invalidMessage
            }
        }
    }
}
