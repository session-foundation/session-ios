// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import SessionUtilitiesKit

// MARK: - Singleton

public extension Singleton {
    static let network: SingletonConfig<NetworkType> = Dependencies.create(
        identifier: "network",
        createInstance: { dependencies, _ in LibSessionNetwork(using: dependencies) }
    )
}

// MARK: - Network Constants

public class Network {
    public static let defaultTimeout: TimeInterval = 10
    public static let fileUploadTimeout: TimeInterval = 60
    public static let fileDownloadTimeout: TimeInterval = 30
    
    /// **Note:** The max file size is 10,000,000 bytes (rather than 10MiB which would be `(10 * 1024 * 1024)`), 10,000,000
    /// exactly will be fine but a single byte more will result in an error
    public static let maxFileSize: UInt = 10_000_000
}

// MARK: - NetworkStatus

public enum NetworkStatus {
    case unknown
    case connecting
    case connected
    case disconnected
}

// MARK: - NetworkType

public protocol NetworkType {
    func getSwarm(for swarmPublicKey: String) -> AnyPublisher<Set<LibSession.Snode>, Error>
    func getRandomNodes(count: Int) -> AnyPublisher<Set<LibSession.Snode>, Error>
    
    func send<E: EndpointType>(
        endpoint: E,
        destination: Network.Destination,
        body: Data?,
        requestTimeout: TimeInterval,
        requestAndPathBuildTimeout: TimeInterval?
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error>
    
    func checkClientVersion(ed25519SecretKey: [UInt8]) -> AnyPublisher<(ResponseInfoType, Network.FileServer.AppVersionResponse), Error>
}
