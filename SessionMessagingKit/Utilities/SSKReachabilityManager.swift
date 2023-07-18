import Reachability

@objc(SSKReachabilityType)
public enum ReachabilityType: Int {
    case any, wifi, cellular
}

@objc
public protocol SSKReachabilityManager {
    var reachability: Reachability { get }
    
    var observationContext: AnyObject { get }
    func setup()

    var isReachable: Bool { get }
    func isReachable(via reachabilityType: ReachabilityType) -> Bool
}
