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
            let line = String(self[start..<end])
            result.append(line)
            start = end
            if start == self.endIndex { break }
        }
        return result.joined(separator: "\n")
    }
}

// MARK: - Truncation

public extension String {
    /// A standardised mechanism for truncating a user id
    ///
    /// stringlint:ignore_contents
    func truncated(prefix: Int = 4, suffix: Int = 4) -> String {
        guard count > (prefix + suffix) else { return self }
        
        return "\(self.prefix(prefix))...\(self.suffix(suffix))"
    }
}

// MARK: - Formatting

public extension String.StringInterpolation {
    mutating func appendInterpolation(_ value: TimeUnit, unit: TimeUnit.Unit, resolution: Int = 2) {
        appendLiteral("\(TimeUnit(value, unit: unit, resolution: resolution))")
    }
    
    mutating func appendInterpolation(_ value: Int, format: String) {
        let result: String = String(format: "%\(format)d", value)
        appendLiteral(result)
    }
    
    mutating func appendInterpolation(_ value: Double, format: String, omitZeroDecimal: Bool = false) {
        guard !omitZeroDecimal || Int(exactly: value) == nil else {
            appendLiteral("\(Int(exactly: value)!)")
            return
        }
        
        let result: String = String(format: "%\(format)f", value)
        appendLiteral(result)
    }
}

public extension String {
    // stringlint:ignore_contents
    static func formattedDuration(
        _ duration: TimeInterval,
        format: TimeInterval.DurationFormat = .short,
        allowedUnits: NSCalendar.Unit = [.weekOfMonth, .day, .hour, .minute, .second]
    ) -> String {
        let dateComponentsFormatter = DateComponentsFormatter()
        dateComponentsFormatter.allowedUnits = allowedUnits
        var calendar = Calendar.current
        
        switch format {
            case .videoDuration:
                guard duration < 3600 else { fallthrough }
                dateComponentsFormatter.allowedUnits = [.minute, .second]
                dateComponentsFormatter.unitsStyle = .positional
                dateComponentsFormatter.zeroFormattingBehavior = .pad
                return dateComponentsFormatter.string(from: duration) ?? ""
            
            case .hoursMinutesSeconds:
                if duration < 3600 {
                    dateComponentsFormatter.allowedUnits = [.minute, .second]
                    dateComponentsFormatter.zeroFormattingBehavior = .pad
                } else {
                    dateComponentsFormatter.allowedUnits = [.hour, .minute, .second]
                    dateComponentsFormatter.zeroFormattingBehavior = .default
                }
                dateComponentsFormatter.unitsStyle = .positional
                // This is a workaroud for 00:00 to be shown as 0:00
                var str: String = dateComponentsFormatter.string(from: duration) ?? ""
                if str.hasPrefix("0") {
                    str.remove(at: str.startIndex)
                }
                return str
                
            case .short: // Single unit, no localization, short version e.g. 1w
                dateComponentsFormatter.maximumUnitCount = 1
                dateComponentsFormatter.unitsStyle = .abbreviated
                calendar.locale = Locale(identifier: "en-US")
                dateComponentsFormatter.calendar = calendar
                return dateComponentsFormatter.string(from: duration) ?? ""
                
            case .long: // Single unit, long version e.g. 1 week
                dateComponentsFormatter.maximumUnitCount = 1
                dateComponentsFormatter.unitsStyle = .full
                return dateComponentsFormatter.string(from: duration) ?? ""
            
            case .twoUnits: // 2 units, no localization, short version e.g 1w 1d, remove trailing 0's e.g 12h 0m -> 12h
                dateComponentsFormatter.maximumUnitCount = 2
                dateComponentsFormatter.unitsStyle = .abbreviated
                dateComponentsFormatter.zeroFormattingBehavior = .dropAll
                calendar.locale = Locale(identifier: "en-US")
                dateComponentsFormatter.calendar = calendar
                return dateComponentsFormatter.string(from: duration) ?? ""
            }
    }
    
    static func formattedRelativeTime(_ timestampMs: Int64, minimumUnit: NSCalendar.Unit) -> String {
        let relativeTimestamp: TimeInterval = (Date().timeIntervalSince1970 - TimeInterval(timestampMs) / 1000)
        var allowedUnits: NSCalendar.Unit = [.weekOfMonth, .day, .hour, .minute, .second]
        
        switch minimumUnit {
            case .minute: allowedUnits.remove(.second)
            default: break
        }
        
        return relativeTimestamp.formatted(format: .short, allowedUnits: allowedUnits)
    }
}
