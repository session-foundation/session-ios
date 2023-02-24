// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import UIKit

extension UIContextualAction {
    
    func setupSessionStyle(with image: UIImage?) {
        guard let title = self.title, let image = image else {
            self.image = image
            return
        }
        
        let text = NSMutableAttributedString(string: "")
        let attachment = NSTextAttachment()
        attachment.image = image.withTintColor(.white)
        text.append(NSAttributedString(attachment: attachment))
        text.append(
            NSAttributedString(
                string: "\n\(title)",
                attributes: [
                    .font : UIFont.systemFont(ofSize: Values.smallFontSize),
                    .foregroundColor : UIColor.white
                ]
            )
        )
        
        let label = UILabel(frame: CGRect(x: 0, y: 0, width: 50, height: 50))
        label.textAlignment = .center
        label.numberOfLines = 2
        label.attributedText = text
        
        let renderer = UIGraphicsImageRenderer(bounds: label.bounds)
        let renderedImage = renderer.image { context in
            label.layer.render(in: context.cgContext)
        }
        if let cgImage = renderedImage.cgImage {
            let finalImage = UIImage(cgImage: cgImage, scale: UIScreen.main.scale, orientation: .up)
            self.image = finalImage
            self.title = nil
        }
    }
}
