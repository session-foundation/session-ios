// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum SessionProUI {}

// MARK: - ClientPlatform

public extension SessionProUI {
    enum ClientPlatform: Sendable, Equatable, CaseIterable {
        case iOS
        case android
        
        public var device: String { SNUIKit.proClientPlatformStringProvider(for: self).device }
        public var store: String { SNUIKit.proClientPlatformStringProvider(for: self).store }
        public var platform: String { SNUIKit.proClientPlatformStringProvider(for: self).platform }
        public var platformAccount: String { SNUIKit.proClientPlatformStringProvider(for: self).platformAccount }
    }
}
