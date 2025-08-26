import Foundation
import SessionUtilitiesKit

public extension Threading {
    static let pollerQueue = DispatchQueue(label: "SessionMessagingKit.pollerQueue")
}
