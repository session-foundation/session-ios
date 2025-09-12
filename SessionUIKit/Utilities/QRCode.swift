// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import UIKit

public enum QRCode {
    /// Generates a QRCode with a logo in the middle for the give string
    ///
    /// **Note:** If the `hasBackground` value is true then the QRCode will be black and white and
    /// the `withRenderingMode(.alwaysTemplate)` won't work correctly on some iOS versions (eg. iOS 16)
    ///
    /// stringlint:ignore_contents
    public static func generate(for string: String, hasBackground: Bool, iconName: String?) -> UIImage {
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
    
    public static func qrCodeImageWithTintAndBackground(
        image: UIImage,
        themeStyle: UIUserInterfaceStyle,
        size: CGSize? = nil,
        insets: UIEdgeInsets = .zero
    ) -> UIImage {
        var backgroundColor: UIColor {
            switch themeStyle {
            case .light: return .classicDark1
                default: return .white
            }
        }
        var tintColor: UIColor {
            switch themeStyle {
                case .light: return .white
                default: return .classicDark1
            }
        }
        
        let outputSize = size ?? image.size
        let renderer = UIGraphicsImageRenderer(size: outputSize)

        return renderer.image { context in
            // Fill background
            backgroundColor.setFill()
            context.fill(CGRect(origin: .zero, size: outputSize))

            // Apply tint using template rendering
            tintColor.setFill()
            let templateImage = image.withRenderingMode(.alwaysTemplate)

            let imageRect = CGRect(
                x: insets.left,
                y: insets.top,
                width: outputSize.width - insets.left - insets.right,
                height: outputSize.height - insets.top - insets.bottom
            )

            templateImage.draw(in: imageRect)
        }
    }
}
