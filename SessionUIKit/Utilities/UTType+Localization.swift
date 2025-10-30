// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UniformTypeIdentifiers

public extension UTType {
    func shortDescription(isVoiceMessage: Bool) -> String {
        if conforms(to: .image) { return "image".localized() }
        if conforms(to: .audio) && isVoiceMessage { return "messageVoice".localized() }
        if conforms(to: .audio) { return "audio".localized() }
        if conforms(to: .video) || conforms(to: .movie) { return "video".localized() }
        
        return "document".localized()
    }
}
