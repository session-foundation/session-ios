// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

public protocol OWSProximityMonitoringManager: AnyObject {
    func add(lifetime: AnyObject)
    func remove(lifetime: AnyObject)
}

public class OWSProximityMonitoringManagerImpl: OWSProximityMonitoringManager {
    var lifetimes: [Weak<AnyObject>] = []

    public init(using dependencies: Dependencies) {
        dependencies[singleton: .appReadiness].runNowOrWhenAppWillBecomeReady { [weak self] in
            self?.setup()
        }
    }

    // MARK: 

    var device: UIDevice {
        return UIDevice.current
    }

    // MARK: 

    @objc
    public func add(lifetime: AnyObject) {
        objc_sync_enter(self)

        if !lifetimes.contains(where: { $0.value === lifetime }) {
            lifetimes.append(Weak(value: lifetime))
        }
        reconcile()

        objc_sync_exit(self)
    }

    @objc
    public func remove(lifetime: AnyObject) {
        objc_sync_enter(self)

        lifetimes = lifetimes.filter { $0.value !== lifetime }
        reconcile()

        objc_sync_exit(self)
    }

    @objc
    public func setup() {
        NotificationCenter.default.addObserver(self, selector: #selector(proximitySensorStateDidChange(notification:)), name: UIDevice.proximityStateDidChangeNotification, object: nil)
    }

    @objc
    func proximitySensorStateDidChange(notification: Notification) {
        // This is crazy, but if we disable `device.isProximityMonitoringEnabled` while
        // `device.proximityState` is true (while the device is held to the ear)
        // then `device.proximityState` remains true, even after we bring the phone
        // away from the ear and re-enable monitoring.
        //
        // To resolve this, we wait to disable proximity monitoring until `proximityState`
        // is false.
        if self.device.proximityState {
            self.add(lifetime: self)
        } else {
            self.remove(lifetime: self)
        }
    }

    func reconcile() {
        lifetimes = lifetimes.filter { $0.value != nil }
        if lifetimes.isEmpty {
            DispatchQueue.main.async {
                Log.debug("[ProximityMonitoringManager] Disabling proximity monitoring")
                self.device.isProximityMonitoringEnabled = false
            }
        } else {
            let lifetimes = self.lifetimes
            DispatchQueue.main.async {
                Log.debug("[ProximityMonitoringManager] willEnable proximity monitoring for lifetimes: \(lifetimes), proximityState: \(self.device.proximityState)")
                self.device.isProximityMonitoringEnabled = true
                Log.debug("[ProximityMonitoringManager] didEnable proximity monitoring for lifetimes: \(lifetimes), proximityState: \(self.device.proximityState)")
            }
        }
    }
}
