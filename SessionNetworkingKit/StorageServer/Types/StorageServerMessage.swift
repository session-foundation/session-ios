// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtilitiesKit

public extension Network.SnodeAPI {
    struct Message: Codable, CustomDebugStringConvertible {
        /// Service nodes cache messages for 14 days so default the expiration for message hashes to '15' days
        /// so we don't end up indefinitely storing records which will never be used
        public static let defaultExpirationMs: Int64 = ((15 * 24 * 60 * 60) * 1000)
        
        /// The storage server allows the timestamp within requests to be off by `60s` before erroring
        public static let serverClockToleranceMs: Int64 = ((1 * 60) * 1000)
        
        public let snode: LibSession.Snode?
        public let swarmPublicKey: String
        public let namespace: Namespace
        public let hash: String
        public let timestampMs: Int64
        public let expirationTimestampMs: Int64
        public let data: Data
        
        public var info: SnodeReceivedMessageInfo? {
            snode.map { snode in
                SnodeReceivedMessageInfo(
                    snode: snode,
                    swarmPublicKey: swarmPublicKey,
                    namespace: namespace,
                    hash: hash,
                    expirationDateMs: expirationTimestampMs
                )
            }
        }
        
        public init?(
            snode: LibSession.Snode?,
            publicKey: String,
            namespace: Namespace,
            rawMessage: GetMessagesResponse.RawMessage
        ) {
            guard let data: Data = Data(base64Encoded: rawMessage.base64EncodedDataString) else {
                Log.error(.network, "Failed to decode data for message: \(rawMessage).")
                return nil
            }
            
            self.snode = snode
            self.swarmPublicKey = publicKey
            self.namespace = namespace
            self.hash = rawMessage.hash
            self.timestampMs = rawMessage.timestampMs
            self.expirationTimestampMs = (rawMessage.expirationMs ?? Network.SnodeAPI.Message.defaultExpirationMs)
            self.data = data
        }
        
        public var debugDescription: String {
            """
            Message(
                swarmPublicKey: \(swarmPublicKey),
                namespace: \(namespace),
                hash: \(hash),
                expirationTimestampMs: \(expirationTimestampMs),
                timestampMs: \(timestampMs),
                data: \(data.base64EncodedString())
            )
            """
        }
    }
}
