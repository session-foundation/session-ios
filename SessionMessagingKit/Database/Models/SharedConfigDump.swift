// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionSnodeKit
import SessionUtilitiesKit

public struct ConfigDump: Codable, Equatable, Hashable, FetchableRecord, PersistableRecord, TableRecord, ColumnExpressible {
    public static var databaseTableName: String { "configDump" }
    
    public typealias Columns = CodingKeys
    public enum CodingKeys: String, CodingKey, ColumnExpression {
        case variant
        case publicKey
        case data
        case combinedMessageHashes
    }
    
    public enum Variant: String, Codable, DatabaseValueConvertible {
        case userProfile
        case contacts
    }
    
    /// The type of config this dump is for
    public let variant: Variant
    
    /// The public key for the swarm this dump is for
    ///
    /// **Note:** For user config items this will be an empty string
    public let publicKey: String
    
    /// The data for this dump
    public let data: Data
    
    /// A comma delimited array of message hashes for previously stored messages on the server
    private let combinedMessageHashes: String?
    
    /// An array of message hashes for previously stored messages on the server
    var messageHashes: [String]? { ConfigDump.messageHashes(from: combinedMessageHashes) }
    
    internal init(
        variant: Variant,
        publicKey: String,
        data: Data,
        messageHashes: [String]?
    ) {
        self.variant = variant
        self.publicKey = publicKey
        self.data = data
        self.combinedMessageHashes = ConfigDump.combinedMessageHashes(from: messageHashes)
    }
}

// MARK: - Convenience

public extension ConfigDump {
    static func combinedMessageHashes(from messageHashes: [String]?) -> String? {
        return messageHashes?.joined(separator: ",")
    }
    
    static func messageHashes(from combinedMessageHashes: String?) -> [String]? {
        return combinedMessageHashes?.components(separatedBy: ",")
    }
}

public extension ConfigDump.Variant {
    static let userVariants: [ConfigDump.Variant] = [ .userProfile, .contacts ]
    
    var configMessageKind: SharedConfigMessage.Kind {
        switch self {
            case .userProfile: return .userProfile
            case .contacts: return .contacts
        }
    }
    
    var namespace: SnodeAPI.Namespace {
        switch self {
            case .userProfile: return SnodeAPI.Namespace.configUserProfile
            case .contacts: return SnodeAPI.Namespace.configContacts
        }
    }
}
