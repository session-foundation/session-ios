// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public extension TimeInterval {
    enum DurationFormat {
        case short
        case long
        case hoursMinutesSeconds
        case videoDuration
        case twoUnits
    }
    
    func formatted(format: DurationFormat, allowedUnits: NSCalendar.Unit = [.weekOfMonth, .day, .hour, .minute, .second]) -> String {
        return String.formattedDuration(self, format: format, allowedUnits: allowedUnits)
    }
    
    func ceilingFormatted(format: DurationFormat, allowedUnits: NSCalendar.Unit = [.weekOfMonth, .day, .hour, .minute, .second]) -> String {
        let seconds = self
        let unitOrder: [(unit: NSCalendar.Unit, seconds: TimeInterval)] = [
            (.weekOfMonth, 7 * 24 * 60 * 60),
            (.day, 24 * 60 * 60),
            (.hour, 60 * 60),
            (.minute, 60),
            (.second, 1)
        ]
        
        var targetUnit: (unit: NSCalendar.Unit, seconds: TimeInterval)?
        for (unit, unitSeconds) in unitOrder.reversed() {
            if allowedUnits.contains(unit) {
                targetUnit = (unit, unitSeconds)
                if seconds <= unitSeconds {
                    break
                }
            }
        }
        
        if let target = targetUnit {
            let ceiledSeconds = ceil(seconds / target.seconds) * target.seconds
            return String.formattedDuration(ceiledSeconds, format: format, allowedUnits: allowedUnits)
        }
        
        return String.formattedDuration(seconds, format: format, allowedUnits: allowedUnits)
    }
}
