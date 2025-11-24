// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation

// MARK: - LinkPreviewManagerType

public protocol LinkPreviewManagerType {
    var areLinkPreviewsEnabled: Bool { get async }
    var hasSeenLinkPreviewSuggestion: Bool { get async }
    
    func setHasSeenLinkPreviewSuggestion(_ value: Bool) async
    func allPreviewUrls(forMessageBodyText body: String) async -> [String]
    func previewUrl(for text: String?, selectedRange: NSRange?) async -> String?
    func ensureLinkPreviewsEnabled() async throws
    func tryToBuildPreviewInfo(previewUrl: String, skipImageDownload: Bool) async throws -> LinkPreviewViewModel
}

public extension LinkPreviewManagerType {
    nonisolated static func isValidLinkUrl(_ urlString: String) -> Bool {
        return (URL(string: urlString) != nil)
    }
    
    func previewUrl(for text: String?) async -> String? {
        return await previewUrl(for: text, selectedRange: nil)
    }
}
