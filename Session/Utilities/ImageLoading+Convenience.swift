// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import SwiftUI
import SessionUIKit
import SessionMessagingKit
import SessionUtilitiesKit

// MARK: - SessionImageView Convenience

public extension SessionImageView {
    @MainActor
    func loadImage(from path: String, onComplete: ((Bool) -> Void)? = nil) {
        loadImage(.url(URL(fileURLWithPath: path)), onComplete: onComplete)
    }
    
    @MainActor
    func loadPlaceholder(seed: String, text: String, size: CGFloat, onComplete: ((Bool) -> Void)? = nil) {
        loadImage(.placeholderIcon(seed: seed, text: text, size: size), onComplete: onComplete)
    }
}
