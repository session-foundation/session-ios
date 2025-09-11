// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public struct GroupAuthData: Codable {
    let groupIdentityPrivateKey: Data?
    let authData: Data?
}
