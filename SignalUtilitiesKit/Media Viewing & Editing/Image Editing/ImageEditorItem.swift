//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import UIKit

public enum ImageEditorError: Int, Error {
    case assertionError
    case invalidInput
}

public enum ImageEditorItemType: Int {
    case test
    case stroke
    case text
}

// MARK: -

// Represented in a "ULO unit" coordinate system
// for source image.
//
// "ULO" coordinate system is "upper-left-origin".
//
// "Unit" coordinate system means values are expressed
// in terms of some other values, in this case the
// width and height of the source image.
//
// * 0.0 = left edge
// * 1.0 = right edge
// * 0.0 = top edge
// * 1.0 = bottom edge
public typealias ImageEditorSample = CGPoint

// MARK: -

// Instances of ImageEditorItem should be treated
// as immutable, once configured.
public class ImageEditorItem {
    public let itemId: String
    public let itemType: ImageEditorItemType

    public init(itemType: ImageEditorItemType) {
        self.itemId = UUID().uuidString
        self.itemType = itemType
    }

    public init(itemId: String, itemType: ImageEditorItemType) {
        self.itemId = itemId
        self.itemType = itemType
    }

    // The scale with which to render this item's content
    // when rendering the "output" image for sending.
    public func outputScale() -> CGFloat {
        return 1.0
    }
}
