// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation

extension PushNotificationAPI {
    struct NotificationMetadata: Codable {
        private enum CodingKeys: String, CodingKey {
            case accountId = "@"
            case hash = "#"
            case namespace = "n"
            case dataLength = "l"
            case dataTooLong = "B"
        }
        
        /// Account ID (such as Session ID or closed group ID) where the message arrived.
        let accountId: String
        
        /// The hash of the message in the swarm.
        let hash: String
        
        /// The swarm namespace in which this message arrived.
        let namespace: Int
        
        /// The length of the message data.  This is always included, even if the message content
        /// itself was too large to fit into the push notification.
        let dataLength: Int
        
        /// This will be `true` if the data was omitted because it was too long to fit in a push
        /// notification (around 2.5kB of raw data), in which case the push notification includes
        /// only this metadata but not the message content itself.
        let dataTooLong: Bool
    }
}

extension PushNotificationAPI.NotificationMetadata {
    init(from decoder: Decoder) throws {
        let container: KeyedDecodingContainer<CodingKeys> = try decoder.container(keyedBy: CodingKeys.self)
        
        self = PushNotificationAPI.NotificationMetadata(
            accountId: try container.decode(String.self, forKey: .accountId),
            hash: try container.decode(String.self, forKey: .hash),
            namespace: try container.decode(Int.self, forKey: .namespace),
            dataLength: try container.decode(Int.self, forKey: .dataLength),
            dataTooLong: ((try? container.decode(Int.self, forKey: .dataTooLong) != 0) ?? false)
        )
    }
}
