// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.

import Foundation

public enum NumberFormat {
    case abbreviated(decimalPlaces: Int, omitZeroDecimal: Bool)
    case decimal
    case currency(decimal: Bool, withLocalSymbol: Bool, roundingMode: NumberFormatter.RoundingMode)
    case abbreviatedCurrency(decimalPlaces: Int, omitZeroDecimal: Bool)
}

public extension NumberFormat {
    static let abbreviated: NumberFormat = .abbreviated(decimalPlaces: 0, omitZeroDecimal: true)
    
    static func abbreviated(decimalPlaces: Int) -> NumberFormat {
        return .abbreviated(decimalPlaces: decimalPlaces, omitZeroDecimal: true)
    }
    
    static let abbreviatedCurrency: NumberFormat = .abbreviatedCurrency(decimalPlaces: 0, omitZeroDecimal: true)
    static func abbreviatedCurrency(decimalPlaces: Int) -> NumberFormat {
        return .abbreviatedCurrency(decimalPlaces: decimalPlaces, omitZeroDecimal: true)
    }
    
    fileprivate func format(_ value: Double) -> String {
        switch self {
            case .abbreviated(let decimalPlaces, let omitZeroDecimal):
                return value.abbreviatedString(decimalPlaces: decimalPlaces, omitZeroDecimal: omitZeroDecimal)
                
            case .decimal:
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
            
            case .currency(let decimal, let withLocalSymbol, let roundingMode):
                let formatter = NumberFormatter()
                formatter.numberStyle = .currency
                if !withLocalSymbol {
                    formatter.currencySymbol = ""
                }
                if !decimal {
                    formatter.minimumFractionDigits = 0
                    formatter.maximumFractionDigits = 0
                }
                formatter.roundingMode = roundingMode
                return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
                
            case .abbreviatedCurrency(let decimalPlaces, let omitZeroDecimal):
                let formatter = NumberFormatter()
                formatter.numberStyle = .currency
                formatter.currencySymbol = ""
                let symbol: String = (formatter.currencySymbol ?? "")
                let abbreviatedNumber: String = value.abbreviatedString(decimalPlaces: decimalPlaces, omitZeroDecimal: omitZeroDecimal)
                let fullFormattedString: String = (formatter.string(from: NSNumber(value: value)) ?? "\(value)")
                
                if !symbol.isEmpty && fullFormattedString.hasPrefix(symbol) {
                    return "\(symbol)\(abbreviatedNumber)"
                }
                
                if !symbol.isEmpty && fullFormattedString.hasSuffix(symbol) {
                    return "\(abbreviatedNumber)\(symbol)"
                }
                
                // Fallback
                return "\(symbol)\(abbreviatedNumber)"
        }
    }
}

public extension Double {
    func formatted(format: NumberFormat) -> String {
        return format.format(self)
    }
}

public extension Int {
    func formatted(format: NumberFormat) -> String {
        return format.format(Double(self))
    }
}

