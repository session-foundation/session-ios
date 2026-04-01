// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public class SessionEnvironment {
    public static var shared: SessionEnvironment?
    
    public let proximityMonitoringManager: OWSProximityMonitoringManager
    public var isRequestingPermission: Bool
    
    // MARK: - Initialization
    
    public init(
        proximityMonitoringManager: OWSProximityMonitoringManager
    ) {
        self.proximityMonitoringManager = proximityMonitoringManager
        self.isRequestingPermission = false
        
        if SessionEnvironment.shared == nil {
            SessionEnvironment.shared = self
        }
    }
    
    // MARK: - Functions
    
    public static func clearSharedForTests() {
        shared = nil
    }
}
