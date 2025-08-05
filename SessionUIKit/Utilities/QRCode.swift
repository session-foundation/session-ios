// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

enum QRCode {
    /// Generates a QRCode for the give string
    ///
    /// **Note:** If the `hasBackground` value is true then the QRCode will be black and white and
    /// the `withRenderingMode(.alwaysTemplate)` won't work correctly on some iOS versions (eg. iOS 16)
    ///
    /// stringlint:ignore_contents
    static func generate(for string: String, hasBackground: Bool) -> UIImage {
        let data = string.data(using: .utf8)
        var qrCodeAsCIImage: CIImage
        let filter1 = CIFilter(name: "CIQRCodeGenerator")!
        filter1.setValue(data, forKey: "inputMessage")
        qrCodeAsCIImage = filter1.outputImage!
        
        guard !hasBackground else {
            let filter2 = CIFilter(name: "CIFalseColor")!
            filter2.setValue(qrCodeAsCIImage, forKey: "inputImage")
            filter2.setValue(CIColor(color: .black), forKey: "inputColor0")
            filter2.setValue(CIColor(color: .white), forKey: "inputColor1")
            qrCodeAsCIImage = filter2.outputImage!
            
            let scaledQRCodeAsCIImage = qrCodeAsCIImage.transformed(by: CGAffineTransform(scaleX: 6.4, y: 6.4))
            return UIImage(ciImage: scaledQRCodeAsCIImage)
        }
        
        let filter2 = CIFilter(name: "CIColorInvert")!
        filter2.setValue(qrCodeAsCIImage, forKey: "inputImage")
        qrCodeAsCIImage = filter2.outputImage!
        let filter3 = CIFilter(name: "CIMaskToAlpha")!
        filter3.setValue(qrCodeAsCIImage, forKey: "inputImage")
        qrCodeAsCIImage = filter3.outputImage!
        
        let scaledQRCodeAsCIImage = qrCodeAsCIImage.transformed(by: CGAffineTransform(scaleX: 6.4, y: 6.4))
        
        // Note: It looks like some internal method was changed in iOS 16.0 where images
        // generated from a CIImage don't have the same color information as normal images
        // as a result tinting using the `alwaysTemplate` rendering mode won't work - to
        // work around this we convert the image to data and then back into an image
        let imageData: Data = UIImage(ciImage: scaledQRCodeAsCIImage).pngData()!
        return UIImage(data: imageData)!
    }
    
    /// Generates a QRCode with a logo in the middle for the give string
    ///
    /// **Note:** If the `hasBackground` value is true then the QRCode will be black and white and
    /// the `withRenderingMode(.alwaysTemplate)` won't work correctly on some iOS versions (eg. iOS 16)
    ///
    /// stringlint:ignore_contents
    static func generate(for string: String, hasBackground: Bool, iconName: String?) -> UIImage {
        // 1. Create QR code data
        guard let data = string.data(using: .utf8),
              let qrFilter = CIFilter(name: "CIQRCodeGenerator") else {
            return UIImage()
        }

        qrFilter.setValue(data, forKey: "inputMessage")
        qrFilter.setValue("H", forKey: "inputCorrectionLevel") // High error correction for embedded icon
        guard var qrCIImage = qrFilter.outputImage else { return UIImage() }

        // 2. Optional coloring
        if hasBackground {
            if let colorFilter = CIFilter(name: "CIFalseColor") {
                colorFilter.setValue(qrCIImage, forKey: "inputImage")
                colorFilter.setValue(CIColor(color: .black), forKey: "inputColor0")
                colorFilter.setValue(CIColor(color: .white), forKey: "inputColor1")
                qrCIImage = colorFilter.outputImage ?? qrCIImage
            }
        } else {
            if let invertFilter = CIFilter(name: "CIColorInvert"),
               let maskFilter = CIFilter(name: "CIMaskToAlpha") {
                invertFilter.setValue(qrCIImage, forKey: "inputImage")
                maskFilter.setValue(invertFilter.outputImage, forKey: "inputImage")
                qrCIImage = maskFilter.outputImage ?? qrCIImage
            }
        }

        // 3. Scale CIImage to high resolution
        let scaleX: CGFloat = 10.0
        let scaleTransform = CGAffineTransform(scaleX: scaleX, y: scaleX)
        let scaledCIImage = qrCIImage.transformed(by: scaleTransform)
        let qrUIImage = UIImage(ciImage: scaledCIImage)

        // 4. Draw final image
        let size = qrUIImage.size
        UIGraphicsBeginImageContextWithOptions(size, false, 0.0)
        qrUIImage.draw(in: CGRect(origin: .zero, size: size))

        // 5. Add icon with white background + 4pt padding
        if
            let iconName = iconName,
            let icon: UIImage = UIImage(named: iconName)
        {
            let iconPercent: CGFloat = 0.25
            let iconSize = size.width * iconPercent
            let iconRect = CGRect(
                x: (size.width - iconSize) / 2,
                y: (size.height - iconSize) / 2,
                width: iconSize,
                height: iconSize
            )

            // Clear the area under the icon
            if let ctx = UIGraphicsGetCurrentContext() {
                ctx.clear(iconRect)
            }

            // Draw the icon over the transparent hole
            icon.draw(in: iconRect)
        }

        let finalImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return finalImage ?? qrUIImage
    }
}
