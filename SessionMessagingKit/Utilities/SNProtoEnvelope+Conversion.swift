// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionNetworkingKit
import SessionUtilitiesKit

public extension SNProtoEnvelope {
    static func from(_ message: SnodeReceivedMessage) -> SNProtoEnvelope? {
        guard let result = try? MessageWrapper.unwrap(data: message.data) else {
            Log.error(.messageReceiver, "Failed to unwrap data for message: \(String(reflecting: message)).")
            return nil
        }
        
        return result
    }
}
