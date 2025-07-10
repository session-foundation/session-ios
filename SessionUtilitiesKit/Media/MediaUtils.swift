// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import UIKit
import AVFoundation

// MARK: - Log.Category

public extension Log.Category {
    static let media: Log.Category = .create("MediaUtils", defaultLevel: .warn)
}

// MARK: - MediaError

public enum MediaError: Error {
    case failure(description: String)
}

// MARK: - MediaUtils

public enum MediaUtils {
    public static var maxFileSizeAnimatedImage: UInt { SNUtilitiesKit.maxFileSize }
    public static var maxFileSizeImage: UInt { SNUtilitiesKit.maxFileSize }
    public static var maxFileSizeVideo: UInt { SNUtilitiesKit.maxFileSize }
    public static var maxFileSizeAudio: UInt { SNUtilitiesKit.maxFileSize }
    public static var maxFileSizeGeneric: UInt { SNUtilitiesKit.maxFileSize }

    public static let maxAnimatedImageDimensions: UInt = 1 * 1024
    public static let maxStillImageDimensions: UInt = 8 * 1024
    public static let maxVideoDimensions: CGFloat = 3 * 1024

    public static func isVideoOfValidContentTypeAndSize(path: String, type: String?, using dependencies: Dependencies) -> Bool {
        guard dependencies[singleton: .fileManager].fileExists(atPath: path) else {
            Log.error(.media, "Media file missing.")
            return false
        }
        guard let type: String = type, UTType.isVideo(type) else {
            Log.error(.media, "Media file has invalid content type.")
            return false
        }

        guard let fileSize: UInt64 = dependencies[singleton: .fileManager].fileSize(of: path) else {
            Log.error(.media, "Media file has unknown length.")
            return false
        }
        return UInt(fileSize) <= SNUtilitiesKit.maxFileSize
    }

    public static func isValidVideo(asset: AVURLAsset) -> Bool {
        var maxTrackSize = CGSize.zero
        for track: AVAssetTrack in asset.tracks(withMediaType: .video) {
            let trackSize: CGSize = track.naturalSize
            maxTrackSize.width = max(maxTrackSize.width, trackSize.width)
            maxTrackSize.height = max(maxTrackSize.height, trackSize.height)
        }
        if maxTrackSize.width < 1.0 || maxTrackSize.height < 1.0 {
            Log.error(.media, "Invalid video size: \(maxTrackSize)")
            return false
        }
        if maxTrackSize.width > maxVideoDimensions || maxTrackSize.height > maxVideoDimensions {
            Log.error(.media, "Invalid video dimensions: \(maxTrackSize)")
            return false
        }
        return true
    }
    
    /// Use `isValidVideo(asset: AVURLAsset)` if the `AVURLAsset` needs to be generated elsewhere in the code,
    /// otherwise this will be inefficient as it can create a temporary file for the `AVURLAsset` on old iOS versions
    public static func isValidVideo(path: String, mimeType: String?, sourceFilename: String?, using dependencies: Dependencies) -> Bool {
        guard
            let assetInfo: (asset: AVURLAsset, cleanup: () -> Void) = AVURLAsset.asset(
                for: path,
                mimeType: mimeType,
                sourceFilename: sourceFilename,
                using: dependencies
            )
        else { return false }
        
        let result: Bool = isValidVideo(asset: assetInfo.asset)
        assetInfo.cleanup()
        
        return result
    }
}
