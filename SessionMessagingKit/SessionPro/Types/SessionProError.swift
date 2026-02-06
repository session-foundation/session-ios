// Copyright © 2025 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

public enum SessionProError: Error, CustomStringConvertible {
    case productNotFound
    case transactionNotFound
    case purchaseCancelled
    case refundCancelled
    case windowSceneRequired
    case failedToShowStoreKitUI(String)
    
    case purchaseFailed(String)
    case refundFailed(String)
    case generateProProofFailed(String)
    case getProDetailsFailed(String)
    case getProRevocationsFailed(String)
    
    case noLatestPaymentItem
    case refundAlreadyRequestedForLatestPayment
    case nonOriginatedLatestPayment
    
    case unhandledBehaviour
    
    public var description: String {
        switch self {
            case .productNotFound: return "The request product was not found."
            case .transactionNotFound: return "The transaction was not found."
            case .purchaseCancelled: return "The purchase was cancelled."
            case .refundCancelled: return "The refund was cancelled."
            case .windowSceneRequired: return "A window scene is required to present the UI."
            case .failedToShowStoreKitUI(let screen): return "Failed to show StoreKit UI: \(screen)."
                
            case .purchaseFailed(let error): return "The purchase failed due to error: \(error)."
            case .refundFailed(let error): return "The refund failed due to error: \(error)."
            case .generateProProofFailed(let error): return "Failed to generate the pro proof due to error: \(error)."
            case .getProDetailsFailed(let error): return "Failed to get pro details due to error: \(error)."
            case .getProRevocationsFailed(let error): return "Failed to retrieve the latest pro revocations due to error: \(error)."
                
            case .noLatestPaymentItem: return "No latest payment item."
            case .refundAlreadyRequestedForLatestPayment: return "Refund already requested for latest payment"
            case .nonOriginatedLatestPayment: return "Latest payment wasn't originated from an Apple device"
                
            case .unhandledBehaviour: return "Unhandled behaviour."
        }
    }
}
