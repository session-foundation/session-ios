// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

public extension Double {
    // stringlint:disable_contents
    func abbreviatedString(decimalPlaces: Int = 0, omitZeroDecimal: Bool = true) -> String {
        typealias TargetValue = (value: Double, suffix: String)
        
        let clampedDecimalPlaces: Int = max(0, decimalPlaces)
        let absNumber: Double = abs(self)
        let targetValue: TargetValue
        
        switch absNumber {
            case (1_000_000_000_000...): targetValue = (self / 1_000_000_000_000, "T")
            case (1_000_000_000...): targetValue = (self / 1_000_000_000, "B")
            case (1_000_000...): targetValue = (self / 1_000_000, "M")
            case (1000...): targetValue = (self / 1000, "K")
            default: targetValue = (self, "")
        }
        
        guard
            decimalPlaces > 0 && (
                !omitZeroDecimal ||
                targetValue.value.truncatingRemainder(dividingBy: 1) != 0
            )
        else { return String(format: "%.0f%@", targetValue.value, targetValue.suffix) }
        
        return String(format: "%.\(clampedDecimalPlaces)f%@", targetValue.value, targetValue.suffix)
    }
}
