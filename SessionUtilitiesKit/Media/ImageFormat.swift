// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum ImageFormat {
    case unknown
    case png
    case gif
    case tiff
    case jpeg
    case bmp
    case webp
    
    // stringlint:ignore_contents
    public var fileExtension: String {
        switch self {
            case .jpeg, .unknown: return "jpg"
            case .png: return "png"
            case .gif: return "gif"
            case .tiff: return "tiff"
            case .bmp: return "bmp"
            case .webp: return "webp"
        }
    }
}
