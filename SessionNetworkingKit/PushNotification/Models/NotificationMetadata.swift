// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension Network.PushNotification {
    struct NotificationMetadata: Codable, Equatable {
        private enum CodingKeys: String, CodingKey {
            case accountId = "@"
            case hash = "#"
            case namespace = "n"
            case createdTimestampMs = "t"
            case expirationTimestampMs = "z"
            case dataLength = "l"
            case dataTooLong = "B"
        }
        
        /// Account ID (such as Session ID or closed group ID) where the message arrived.
        public let accountId: String
        
        /// The hash of the message in the swarm.
        public let hash: String
        
        /// The swarm namespace in which this message arrived.
        public let namespace: Network.SnodeAPI.Namespace
        
        /// The swarm timestamp when the message was created (unix epoch milliseconds)
        public let createdTimestampMs: Int64
        
        /// The message's swarm expiry timestamp (unix epoch milliseconds)
        public let expirationTimestampMs: Int64
        
        /// The length of the message data.  This is always included, even if the message content
        /// itself was too large to fit into the push notification.
        public let dataLength: Int
        
        /// This will be `true` if the data was omitted because it was too long to fit in a push
        /// notification (around 2.5kB of raw data), in which case the push notification includes
        /// only this metadata but not the message content itself.
        public let dataTooLong: Bool
    }
}

// MARK: - Decodable

extension Network.PushNotification.NotificationMetadata {
    public init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        /// There was a bug at one point where the metadata would include a `null` value for the namespace because we were storing
        /// messages in a namespace that the storage server didn't have an explicit `namespace_id` for, as a result we need to assume
        /// that the `namespace` value may not be present in the payload
        let namespace: Network.SnodeAPI.Namespace = try container
            .decodeIfPresent(Int.self, forKey: .namespace)
            .map { Network.SnodeAPI.Namespace(rawValue: $0) }
            .defaulting(to: .unknown)
        
        self = Network.PushNotification.NotificationMetadata(
            accountId: try container.decode(String.self, forKey: .accountId),
            hash: try container.decode(String.self, forKey: .hash),
            namespace: namespace,
            createdTimestampMs: try container.decode(Int64.self, forKey: .createdTimestampMs),
            expirationTimestampMs: try container.decode(Int64.self, forKey: .expirationTimestampMs),
            dataLength: try container.decode(Int.self, forKey: .dataLength),
            dataTooLong: ((try? container.decode(Int.self, forKey: .dataTooLong) != 0) ?? false)
        )
    }
}

// MARK: - Convenience

public extension Network.PushNotification.NotificationMetadata {
    static var invalid: Network.PushNotification.NotificationMetadata {
        Network.PushNotification.NotificationMetadata(
            accountId: "",
            hash: "",
            namespace: .unknown,
            createdTimestampMs: 0,
            expirationTimestampMs: 0,
            dataLength: 0,
            dataTooLong: false
        )
    }
}
