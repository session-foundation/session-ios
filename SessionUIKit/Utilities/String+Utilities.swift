// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import UIKit

extension String {
    public func heightWithConstrainedWidth(width: CGFloat, font: UIFont) -> CGFloat {
        let constraintRect = CGSize(width: width, height: .greatestFiniteMagnitude)
        let boundingBox = self.boundingRect(
            with: constraintRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [NSAttributedString.Key.font: font],
            context: nil
        )
        return boundingBox.height
    }
    
    public func widthWithNumberOfLines(lines: Int = 1, font: UIFont) -> CGFloat {
        let constraintRect = CGSize(width: .greatestFiniteMagnitude, height: font.lineHeight * CGFloat(lines))
        let boundingBox = self.boundingRect(
            with: constraintRect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [NSAttributedString.Key.font: font],
            context: nil
        )
        return boundingBox.width
    }
}

public extension String {
    func splitIntoLines(charactersForLines: [Int]) -> String {
        var result: [String] = []
        var start = self.startIndex

        for count in charactersForLines {
            let end = self.index(start, offsetBy: count, limitedBy: self.endIndex) ?? self.endIndex
            var line = String(self[start..<end])
            result.append(line)
            start = end
            if start == self.endIndex { break }
        }
        return result.joined(separator: "\n")
    }
}
