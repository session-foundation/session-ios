// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine

public protocol SessionProManagerType: AnyObject {
    var isSessionProSubject: CurrentValueSubject<Bool, Never> { get }
    var isSessionProPublisher: AnyPublisher<Bool, Never> { get }
    var sessionProPlans: [SessionProPlan] { get }
    var isAutoRenewEnabled: Bool { get }
    var originatingPlatform: ClientPlatform { get }
    var currentPlan: SessionProPlan? { get }
    var currentPlanExpiredOn: Date? { get }
    func upgradeToPro(completion: ((_ result: Bool) -> Void)?)
}

public struct SessionProPlan: Equatable {
    public enum Variant {
        case oneMonth, threeMonths, twelveMonths
        
        public static var allCases: [Variant] { [.twelveMonths, .threeMonths, .oneMonth] }
        
        public var duration: Int {
            switch self {
                case .oneMonth: return 1
                case .threeMonths: return 3
                case .twelveMonths: return 12
            }
        }
        
        public var durationString: String {
            let formatter = DateComponentsFormatter()
            formatter.unitsStyle = .full
            formatter.allowedUnits = [.month]
            let components = DateComponents(month: self.duration)
            return formatter.string(from: components) ?? "\(self.duration) months"
        }
        
        // MARK: - Mock
        public var price: Double {
            switch self {
                case .oneMonth: return 5.99
                case .threeMonths: return 14.99
                case .twelveMonths: return 47.99
            }
        }
        
        public var discountPercent: Int? {
            switch self {
                case .oneMonth: return nil
                case .threeMonths: return 16
                case .twelveMonths: return 33
            }
        }
    }
    
    public let variant: Variant
    public let price: Double
    public var titleWithPrice: String {
        switch variant {
            case .oneMonth: 
                return "proPriceOneMonth"
                    .put(key: "monthly_price", value: pricePerMonth.formatted(format: .currency(decimal: true, withLocalSymbol: true)))
                    .localized()
            case .threeMonths:
                return "proPriceThreeMonths"
                    .put(key: "monthly_price", value: pricePerMonth.formatted(format: .currency(decimal: true, withLocalSymbol: true)))
                    .localized()
            case .twelveMonths:
                return "proPriceTwelveMonths"
                    .put(key: "monthly_price", value: pricePerMonth.formatted(format: .currency(decimal: true, withLocalSymbol: true)))
                    .localized()
        }
    }
    public var pricePerMonth: Double { price / Double(variant.duration) }
    public var subtitleWithPrice: String {
        switch variant {
            case .oneMonth:
                return "proBilledMonthly"
                    .put(key: "price", value: price.formatted(format: .currency(decimal: true, withLocalSymbol: true)))
                    .localized()
            case .threeMonths:
                return "proBilledQuarterly"
                    .put(key: "price", value: price.formatted(format: .currency(decimal: true, withLocalSymbol: true)))
                    .localized()
            case .twelveMonths:
                return "proBilledAnnually"
                    .put(key: "price", value: price.formatted(format: .currency(decimal: true, withLocalSymbol: true)))
                    .localized()
        }
    }
    public let discountPercent: Int?
    
    public init(variant: Variant, price: Double, discountPercent: Int?) {
        self.variant = variant
        self.price = price
        self.discountPercent = discountPercent
    }
    
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.variant  == rhs.variant
    }
}

public enum ClientPlatform {
    case iOS
    case Android
    
    public var store: String {
        switch self {
            case .iOS: return "Apple App"
            case .Android: return "Google Play"
        }
    }
    
    public var account: String {
        switch self {
            case .iOS: return "Apple Account"
            case .Android: return "Google Account"
        }
    }
    
    public var deviceType: String {
        switch self {
            case .iOS: return "iOS"
            case .Android: return "Android"
        }
    }
}
