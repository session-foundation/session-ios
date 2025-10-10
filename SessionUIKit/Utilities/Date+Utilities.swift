// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation

public extension Date {
    var formattedForDisplay: String {
        // If we don't have a date then
        guard self.timeIntervalSince1970 > 0 else { return "" }
        
        let dateNow: Date = Date()
        
        guard Calendar.current.isDate(self, equalTo: dateNow, toGranularity: .year) else {
            // Last year formatter: Nov 11 13:32 am, 2017
            return Date.oldDateFormatter.string(from: self)
        }
        
        guard Calendar.current.isDate(self, equalTo: dateNow, toGranularity: .weekOfYear) else {
            // This year formatter: Jun 6 10:12 am
            return Date.thisYearFormatter.string(from: self)
        }
        
        guard Calendar.current.isDate(self, equalTo: dateNow, toGranularity: .day) else {
            // Day of week formatter: Thu 9:11 pm
            return Date.thisWeekFormatter.string(from: self)
        }
        
        return Date.todayFormatter.string(from: self)
    }
    
    var fromattedForMessageInfo: String {
        let formatter: DateFormatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = "h:mm a EEE, dd/MM/YYYY"
        
        return formatter.string(from: self)
    }
    
    func formatted(_ dateFormat: String) -> String {
        let formatter: DateFormatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.dateFormat = dateFormat
        
        return formatter.string(from: self)
    }
    
    var formattedForBanner: String {
        return Date.localTimeAndDateFormatter.string(from: self)
    }
    
    static func fromHTTPExpiresHeaders(_ expiresValue: String?) -> Date? {
        guard let expiresValue else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE',' dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: expiresValue)
    }
}

// MARK: - Formatters

fileprivate extension Date {
    static let oldDateFormatter: DateFormatter = {
        let result: DateFormatter = DateFormatter()
        result.locale = Locale.current
        result.dateStyle = .medium
        result.timeStyle = .short
        result.doesRelativeDateFormatting = true
        
        return result
    }()
    
    static let thisYearFormatter: DateFormatter = {
        let result: DateFormatter = DateFormatter()
        result.locale = Locale.current
        
        // Jun 6 10:12 am
        result.dateFormat = "MMM d \(hourFormat)"
        
        return result
    }()
    
    static let thisWeekFormatter: DateFormatter = {
        let result: DateFormatter = DateFormatter()
        result.locale = Locale.current
        
        // Mon 11:36 pm
        result.dateFormat = "EEE \(hourFormat)"
        
        return result
    }()
    
    static let todayFormatter: DateFormatter = {
        let result: DateFormatter = DateFormatter()
        result.locale = Locale.current
        
        // 9:10 am
        result.dateFormat = hourFormat
        
        return result
    }()
    
    static let dateOnlyFormatter: DateFormatter = {
        let result: DateFormatter = DateFormatter()
        result.locale = Locale.current
        
        // 6 Jun 2023
        result.dateFormat = "d MMM YYYY"
        
        return result
    }()
    
    static let localTimeAndDateFormatter: DateFormatter = {
        let result: DateFormatter = DateFormatter()
        result.locale = Locale.current
        
        // 2:12pm 6 Jun 2023
        result.dateFormat = "h:mm a, d MMM YYYY"
        
        return result
    }()
    
    static var hourFormat: String {
        guard
            let format: String = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: Locale.current),
            format.range(of: "a") != nil
        else {
            // If we didn't find 'a' then it's 24-hour time
            return "HH:mm"
        }
        
        // If we found 'a' in the format then it's 12-hour time
        return "h:mm a"
    }
}
