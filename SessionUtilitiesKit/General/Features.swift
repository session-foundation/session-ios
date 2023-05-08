
@objc(SNFeatures)
public final class Features : NSObject {
    public static let useOnionRequests = true
    public static let useTestnet = false
    
//    public static let useNewDisappearingMessagesConfig: Bool = Date().timeIntervalSince1970 > 1671062400 // 15/12/2022
    public static let useNewDisappearingMessagesConfig: Bool = true
}
