import Foundation

public enum Threading {
    public static let pollerQueue = DispatchQueue(label: "SessionMessagingKit.pollerQueue")
}
