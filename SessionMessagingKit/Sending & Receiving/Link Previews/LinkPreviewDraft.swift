// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUIKit

public struct LinkPreviewDraft: Sendable, Equatable, Hashable {
    public var urlString: String
    public var title: String?
    public var imageSource: ImageDataManager.DataSource?

    public init(urlString: String, title: String?, imageSource: ImageDataManager.DataSource? = nil) {
        self.urlString = urlString
        self.title = title
        self.imageSource = imageSource
    }

    public func isValid() -> Bool {
        let hasTitle = (title == nil || title?.isEmpty == false)
        let hasImage: Bool = (imageSource != nil)
        
        return (hasTitle || hasImage)
    }
}
