// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation

/// **Note:** The below code **MUST** match the equivalent in `SessionUtilitiesKit.Data+Utilities`
internal extension Data {
    var suiKitGuessedImageFormat: SUIKImageFormat {
        let twoBytesLength: Int = 2
        
        guard count > twoBytesLength else { return .unknown }
        
        var bytes: [UInt8] = [UInt8](repeating: 0, count: twoBytesLength)
        self.copyBytes(to: &bytes, from: (self.startIndex..<self.startIndex.advanced(by: twoBytesLength)))
        
        switch (bytes[0], bytes[1]) {
            case (0x47, 0x49): return .gif
            case (0x89, 0x50): return .png
            case (0xff, 0xd8): return .jpeg
            case (0x42, 0x4d): return .bmp
            case (0x4D, 0x4D): return .tiff // Motorola byte order TIFF
            case (0x49, 0x49): return .tiff // Intel byte order TIFF
            case (0x52, 0x49): return .webp // First two letters of WebP
                
            default: return .unknown
        }
    }
    
    // Parse the GIF header to prevent the "GIF of death" issue.
    //
    // See: https://blog.flanker017.me/cve-2017-2416-gif-remote-exec/
    // See: https://www.w3.org/Graphics/GIF/spec-gif89a.txt
    var suiKitHasValidGifSize: Bool {
        let signatureLength: Int = 3
        let versionLength: Int = 3
        let widthLength: Int = 2
        let heightLength: Int = 2
        let prefixLength: Int = (signatureLength + versionLength)
        let bufferLength: Int = (signatureLength + versionLength + widthLength + heightLength)
        
        guard count > bufferLength else { return false }

        var bytes: [UInt8] = [UInt8](repeating: 0, count: bufferLength)
        self.copyBytes(to: &bytes, from: (self.startIndex..<self.startIndex.advanced(by: bufferLength)))

        let gif87APrefix: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x37, 0x61]
        let gif89APrefix: [UInt8] = [0x47, 0x49, 0x46, 0x38, 0x39, 0x61]
        
        guard bytes.starts(with: gif87APrefix) || bytes.starts(with: gif89APrefix) else {
            return false
        }
        
        let width: UInt = (UInt(bytes[prefixLength]) | (UInt(bytes[prefixLength + 1]) << 8))
        let height: UInt = (UInt(bytes[prefixLength + 2]) | (UInt(bytes[prefixLength + 3]) << 8))

        // We need to ensure that the image size is "reasonable"
        // We impose an arbitrary "very large" limit on image size
        // to eliminate harmful values
        let maxValidSize: UInt = (1 << 18)

        return (width > 0 && width < maxValidSize && height > 0 && height < maxValidSize)
    }
}
