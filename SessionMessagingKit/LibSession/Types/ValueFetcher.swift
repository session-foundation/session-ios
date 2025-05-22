// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUIKit
import SessionUtilitiesKit

public protocol ValueFetcher {
    var userSessionId: SessionId { get }
    
    func has(_ key: Setting.BoolKey) -> Bool
    func has(_ key: Setting.EnumKey) -> Bool
    func get(_ key: Setting.BoolKey) -> Bool
    func get<T: RawRepresentable>(_ key: Setting.EnumKey) -> T? where T.RawValue == Int
    
    func profile(
        contactId: String,
        threadId: String?,
        threadVariant: SessionThread.Variant?,
        visibleMessage: VisibleMessage?
    ) -> Profile?
}

public extension ValueFetcher {
    var profile: Profile {
        return profile(contactId: userSessionId.hexString, threadId: nil, threadVariant: nil, visibleMessage: nil)
            .defaulting(to: Profile(id: userSessionId.hexString, name: "anonymous".localized()))
    }

    func profile(contactId: String) -> Profile? {
        return profile(contactId: contactId, threadId: nil, threadVariant: nil, visibleMessage: nil)
    }
}
