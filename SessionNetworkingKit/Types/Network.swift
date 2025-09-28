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
        createInstance: { dependencies, _ in LibSessionNetwork(singlePathMode: false, using: dependencies) }
    )
}

// MARK: - NetworkType

public protocol NetworkType {
    var isSuspended: Bool { get async }
    var hardfork: Int { get async }
    var softfork: Int { get async }
    var networkTimeOffsetMs: Int64 { get async }
    
    nonisolated var networkStatus: AsyncStream<NetworkStatus> { get }
    @available(*, deprecated, message: "Should try to refactor the code to use proper async/await")
    nonisolated var syncState: NetworkSyncState { get }
    
    func getActivePaths() async throws -> [LibSession.Path]
    func getSwarm(for swarmPublicKey: String) async throws -> Set<LibSession.Snode>
    func getRandomNodes(count: Int) async throws -> Set<LibSession.Snode>
    
    @available(*, deprecated, message: "We want to shift from Combine to Async/Await when possible")
    nonisolated func send<E: EndpointType>(
        endpoint: E,
        destination: Network.Destination,
        body: Data?,
        category: Network.RequestCategory,
        requestTimeout: TimeInterval,
        overallTimeout: TimeInterval?
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error>
    
    func send<E: EndpointType>(
        endpoint: E,
        destination: Network.Destination,
        body: Data?,
        category: Network.RequestCategory,
        requestTimeout: TimeInterval,
        overallTimeout: TimeInterval?
    ) async throws -> (info: ResponseInfoType, value: Data?)
    
    func checkClientVersion(ed25519SecretKey: [UInt8]) async throws -> (info: ResponseInfoType, value: Network.FileServer.AppVersionResponse)
    
    func resetNetworkStatus() async
    func setNetworkStatus(status: NetworkStatus) async
    func setNetworkInfo(networkTimeOffsetMs: Int64, hardfork: Int, softfork: Int) async
    func suspendNetworkAccess() async
    func resumeNetworkAccess(autoReconnect: Bool) async
    func finishCurrentObservations() async
    func clearCache() async
}

public extension NetworkType {
    func resumeNetworkAccess() async {
        await resumeNetworkAccess(autoReconnect: true)
    }
    
    func checkClientVersion(ed25519SecretKey: [UInt8]) async throws -> Network.FileServer.AppVersionResponse {
        return try await checkClientVersion(ed25519SecretKey: ed25519SecretKey).value
    }
}

/// We manually handle thread-safety using the `NSLock` so can ensure this is `Sendable`
public final class NetworkSyncState: @unchecked Sendable {
    private let lock = NSLock()
    private let _dependencies: Dependencies
    private var _hardfork: Int
    private var _softfork: Int
    private var _networkTimeOffsetMs: Int64
    private var _isSuspended: Bool
    
    public init(
        hardfork: Int,
        softfork: Int,
        networkTimeOffsetMs: Int64 = 0,
        isSuspended: Bool = false,
        using dependencies: Dependencies
    ) {
        self._dependencies = dependencies
        self._hardfork = hardfork
        self._softfork = softfork
        self._networkTimeOffsetMs = networkTimeOffsetMs
        self._isSuspended = isSuspended
    }
    
    internal var dependencies: Dependencies { lock.withLock { _dependencies } }
    public var hardfork: Int { lock.withLock { _hardfork } }
    public var softfork: Int { lock.withLock { _softfork } }
    public var networkTimeOffsetMs: Int64 { lock.withLock { _networkTimeOffsetMs } }
    public var isSuspended: Bool { lock.withLock { _isSuspended } }

    func update(
        hardfork: Int? = nil,
        softfork: Int? = nil,
        networkTimeOffsetMs: Int64? = nil,
        isSuspended: Bool? = nil
    ) {
        lock.withLock {
            self._hardfork = (hardfork ?? self._hardfork)
            self._softfork = (softfork ?? self._softfork)
            self._networkTimeOffsetMs = (networkTimeOffsetMs ?? self._networkTimeOffsetMs)
            self._isSuspended = (isSuspended ?? self._isSuspended)
        }
    }
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
