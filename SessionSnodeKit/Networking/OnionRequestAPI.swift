// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import CryptoKit
import GRDB
import SessionUtilitiesKit

public extension Network.RequestType {
    static func onionRequest(
        _ payload: Data,
        to snode: Snode,
        swarmPublicKey: String?,
        timeout: TimeInterval = Network.defaultTimeout
    ) -> Network.RequestType<Data?> {
        return Network.RequestType(
            id: "onionRequest",
            url: "quic://\(snode.ip):\(snode.lmqPort)",
            method: "POST",
            body: payload,
            args: [payload, snode, swarmPublicKey, timeout]
        ) { dependencies in
            OnionRequestAPI.sendOnionRequest(
                with: payload,
                to: OnionRequestAPIDestination.snode(snode),
                swarmPublicKey: swarmPublicKey,
                timeout: timeout,
                using: dependencies
            )
        }
    }
    
    static func onionRequest<E: EndpointType>(
        _ request: URLRequest,
        to server: String,
        endpoint: E,
        with x25519PublicKey: String,
        timeout: TimeInterval = Network.defaultTimeout
    ) -> Network.RequestType<Data?> {
        return Network.RequestType(
            id: "onionRequest",
            url: request.url?.absoluteString,
            method: request.httpMethod,
            headers: request.allHTTPHeaderFields,
            body: request.httpBody,
            args: [request, server, endpoint, x25519PublicKey, timeout]
        ) { dependencies in
            guard let url = request.url, let host = request.url?.host else {
                return Fail(error: NetworkError.invalidURL).eraseToAnyPublisher()
            }
            
            return OnionRequestAPI.sendOnionRequest(
                with: request.httpBody,
                to: OnionRequestAPIDestination.server(
                    method: request.httpMethod,
                    scheme: url.scheme,
                    host: host,
                    endpoint: endpoint,
                    port: url.port.map { UInt16($0) },
                    headers: request.allHTTPHeaderFields,
                    queryParams: request.url?.query?
                        .split(separator: "&")
                        .map { $0.split(separator: "=").map { String($0) } }
                        .reduce(into: [:]) { result, next in
                            guard next.count == 2 else { return }
                            
                            result[next[0]] = next[1]
                        },
                    x25519PublicKey: x25519PublicKey
                ),
                swarmPublicKey: nil,
                timeout: timeout,
                using: dependencies
            )
        }
    }
}

/// See the "Onion Requests" section of [The Session Whitepaper](https://arxiv.org/pdf/2002.04609.pdf) for more information.
public enum OnionRequestAPI {
    private static var buildPathsPublisher: Atomic<AnyPublisher<[[Snode]], Error>?> = Atomic(nil)
    internal static var pathFailureCount: Atomic<[[Snode]: UInt]> = Atomic([:])
    public static var guardSnodes: Atomic<Set<Snode>> = Atomic([])
    
    // Not a set to ensure we consistently show the same path to the user
    private static var _paths: Atomic<[[Snode]]?> = Atomic(nil)
    public static var paths: [[Snode]] {
        get {
            if let paths: [[Snode]] = _paths.wrappedValue { return paths }
            
            let results: [[Snode]]? = Storage.shared.read { db in
                try? Snode.fetchAllOnionRequestPaths(db)
            }
            
            if results?.isEmpty == false { _paths.mutate { $0 = results } }
            return (results ?? [])
        }
        set { _paths.mutate { $0 = newValue } }
    }

    // MARK: - Settings
    
    public static let maxRequestSize = 10_000_000 // 10 MB
    /// The number of snodes (including the guard snode) in a path.
    private static let pathSize: UInt = 3
    /// The number of times a path can fail before it's replaced.
    private static let pathFailureThreshold: UInt = 3
    /// The number of times a snode can fail before it's replaced.
    private static let snodeFailureThreshold: UInt = 3
    /// The number of paths to maintain.
    public static let targetPathCount: UInt = 2

    /// The number of guard snodes required to maintain `targetPathCount` paths.
    private static var targetGuardSnodeCount: UInt { return targetPathCount } // One per path
    
    // MARK: - Onion Building Result
    
    private typealias OnionBuildingResult = (guardSnode: Snode, finalEncryptionResult: AES.GCM.EncryptionResult, destinationSymmetricKey: Data)

    // MARK: - Private API
    
    /// Finds `targetGuardSnodeCount` guard snodes to use for path building. The returned promise errors out with
    /// `Error.insufficientSnodes` if not enough (reliable) snodes are available.
    private static func getGuardSnodes(
        reusing reusableGuardSnodes: [Snode],
        ed25519SecretKey: [UInt8]?,
        using dependencies: Dependencies
    ) -> AnyPublisher<Set<Snode>, Error> {
        guard guardSnodes.wrappedValue.count < targetGuardSnodeCount else {
            return Just(guardSnodes.wrappedValue)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        
        SNLog("Populating guard snode cache.")
        // Sync on LokiAPI.workQueue
        var unusedSnodes = SnodeAPI.snodePool.wrappedValue.subtracting(reusableGuardSnodes)
        let reusableGuardSnodeCount = UInt(reusableGuardSnodes.count)
        
        guard unusedSnodes.count >= (targetGuardSnodeCount - reusableGuardSnodeCount) else {
            return Fail(error: SnodeAPIError.insufficientSnodes)
                .eraseToAnyPublisher()
        }
        
        func getGuardSnode() -> AnyPublisher<Snode, Error> {
            // randomElement() uses the system's default random generator, which
            // is cryptographically secure
            guard let candidate = unusedSnodes.randomElement() else {
                return Fail(error: SnodeAPIError.insufficientSnodes)
                    .eraseToAnyPublisher()
            }
            
            unusedSnodes.remove(candidate) // All used snodes should be unique
            SNLog("Testing guard snode: \(candidate).")
            
            // Loop until a reliable guard snode is found
            return SnodeAPI
                .testSnode(
                    snode: candidate,
                    ed25519SecretKey: ed25519SecretKey,
                    using: dependencies
                )
                .map { _ in candidate }
                .catch { _ in
                    return Just(())
                        .setFailureType(to: Error.self)
                        .delay(for: .milliseconds(100), scheduler: Threading.workQueue)
                        .flatMap { _ in getGuardSnode() }
                }
                .eraseToAnyPublisher()
        }
        
        let publishers = (0..<(targetGuardSnodeCount - reusableGuardSnodeCount))
            .map { _ in getGuardSnode() }
        
        return Publishers.MergeMany(publishers)
            .collect()
            .map { output in Set(output) }
            .handleEvents(
                receiveOutput: { output in
                    OnionRequestAPI.guardSnodes.mutate { $0 = output }
                }
            )
            .eraseToAnyPublisher()
    }
    
    /// Builds and returns `targetPathCount` paths. The returned promise errors out with `Error.insufficientSnodes`
    /// if not enough (reliable) snodes are available.
    @discardableResult
    private static func buildPaths(
        reusing reusablePaths: [[Snode]],
        ed25519SecretKey: [UInt8]?,
        using dependencies: Dependencies
    ) -> AnyPublisher<[[Snode]], Error> {
        if let existingBuildPathsPublisher = buildPathsPublisher.wrappedValue {
            return existingBuildPathsPublisher
        }
        
        return buildPathsPublisher.mutate { result in
            /// It was possible for multiple threads to call this at the same time resulting in duplicate promises getting created, while
            /// this should no longer be possible (as the `wrappedValue` should now properly be blocked) this is a sanity check
            /// to make sure we don't create an additional promise when one already exists
            if let previouslyBlockedPublisher: AnyPublisher<[[Snode]], Error> = result {
                return previouslyBlockedPublisher
            }
            
            SNLog("Building onion request paths.")
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .buildingPaths, object: nil)
            }
            
            /// Need to include the post-request code and a `shareReplay` within the publisher otherwise it can still be executed
            /// multiple times as a result of multiple subscribers
            let reusableGuardSnodes = reusablePaths.map { $0[0] }
            let publisher: AnyPublisher<[[Snode]], Error> = getGuardSnodes(reusing: reusableGuardSnodes, ed25519SecretKey: ed25519SecretKey, using: dependencies)
                .flatMap { (guardSnodes: Set<Snode>) -> AnyPublisher<[[Snode]], Error> in
                    var unusedSnodes: Set<Snode> = SnodeAPI.snodePool.wrappedValue
                        .subtracting(guardSnodes)
                        .subtracting(reusablePaths.flatMap { $0 })
                    let reusableGuardSnodeCount: UInt = UInt(reusableGuardSnodes.count)
                    let pathSnodeCount: UInt = (targetGuardSnodeCount - reusableGuardSnodeCount) * pathSize - (targetGuardSnodeCount - reusableGuardSnodeCount)
                    
                    guard unusedSnodes.count >= pathSnodeCount else {
                        return Fail<[[Snode]], Error>(error: SnodeAPIError.insufficientSnodes)
                            .eraseToAnyPublisher()
                    }
                    
                    // Don't test path snodes as this would reveal the user's IP to them
                    let paths: [[Snode]] = guardSnodes
                        .subtracting(reusableGuardSnodes)
                        .map { (guardSnode: Snode) in
                            let result: [Snode] = [guardSnode]
                                .appending(
                                    contentsOf: (0..<(pathSize - 1))
                                        .map { _ in
                                            // randomElement() uses the system's default random generator,
                                            // which is cryptographically secure
                                            let pathSnode: Snode = unusedSnodes.randomElement()! // Safe because of the pathSnodeCount check above
                                            unusedSnodes.remove(pathSnode) // All used snodes should be unique
                                            return pathSnode
                                        }
                                    )
                            
                            SNLog("Built new onion request path: \(result.prettifiedDescription).")
                            return result
                        }
                    
                    return Just(paths)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                .handleEvents(
                    receiveOutput: { output in
                        OnionRequestAPI.paths = (output + reusablePaths)
                        
                        Storage.shared.write { db in
                            SNLog("Persisting onion request paths to database.")
                            try? output.save(db)
                        }
                        
                        DispatchQueue.main.async {
                            NotificationCenter.default.post(name: .pathsBuilt, object: nil)
                        }
                    },
                    receiveCompletion: { _ in buildPathsPublisher.mutate { $0 = nil } }
                )
                .shareReplay(1)
                .eraseToAnyPublisher()
            
            /// Actually assign the atomic value
            result = publisher
            
            return publisher
        }
    }
    
    /// Returns a `Path` to be used for building an onion request. Builds new paths as needed.
    internal static func getPath(
        excluding snode: Snode?,
        ed25519SecretKey: [UInt8]?,
        using dependencies: Dependencies
    ) -> AnyPublisher<[Snode], Error> {
        guard pathSize >= 1 else { preconditionFailure("Can't build path of size zero.") }
        
        let paths: [[Snode]] = OnionRequestAPI.paths
        var cancellable: [AnyCancellable] = []
        
        if !paths.isEmpty {
            guardSnodes.mutate {
                $0.formUnion([ paths[0][0] ])
                
                if paths.count >= 2 {
                    $0.formUnion([ paths[1][0] ])
                }
            }
        }
        
        // randomElement() uses the system's default random generator, which is cryptographically secure
        if
            paths.count >= targetPathCount,
            let targetPath: [Snode] = paths
                .filter({ snode == nil || !$0.contains(snode!) })
                .randomElement()
        {
            return Just(targetPath)
                .setFailureType(to: Error.self)
                .eraseToAnyPublisher()
        }
        else if !paths.isEmpty {
            if let snode = snode {
                if let path = paths.first(where: { !$0.contains(snode) }) {
                    buildPaths(reusing: paths, ed25519SecretKey: ed25519SecretKey, using: dependencies) // Re-build paths in the background
                        .subscribe(on: DispatchQueue.global(qos: .background), using: dependencies)
                        .sink(receiveCompletion: { _ in cancellable = [] }, receiveValue: { _ in })
                        .store(in: &cancellable)
                    
                    return Just(path)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                else {
                    return buildPaths(reusing: paths, ed25519SecretKey: ed25519SecretKey, using: dependencies)
                        .flatMap { paths in
                            guard let path: [Snode] = paths.filter({ !$0.contains(snode) }).randomElement() else {
                                return Fail<[Snode], Error>(error: SnodeAPIError.insufficientSnodes)
                                    .eraseToAnyPublisher()
                            }
                            
                            return Just(path)
                                .setFailureType(to: Error.self)
                                .eraseToAnyPublisher()
                        }
                        .eraseToAnyPublisher()
                }
            }
            else {
                buildPaths(reusing: paths, ed25519SecretKey: ed25519SecretKey, using: dependencies) // Re-build paths in the background
                    .subscribe(on: DispatchQueue.global(qos: .background))
                    .sink(receiveCompletion: { _ in cancellable = [] }, receiveValue: { _ in })
                    .store(in: &cancellable)
                
                guard let path: [Snode] = paths.randomElement() else {
                    return Fail<[Snode], Error>(error: SnodeAPIError.insufficientSnodes)
                        .eraseToAnyPublisher()
                }
                
                return Just(path)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
        }
        else {
            return buildPaths(reusing: [], ed25519SecretKey: ed25519SecretKey, using: dependencies)
                .flatMap { paths in
                    if let snode = snode {
                        if let path = paths.filter({ !$0.contains(snode) }).randomElement() {
                            return Just(path)
                                .setFailureType(to: Error.self)
                                .eraseToAnyPublisher()
                        }
                        
                        return Fail<[Snode], Error>(error: SnodeAPIError.insufficientSnodes)
                            .eraseToAnyPublisher()
                    }
                    
                    guard let path: [Snode] = paths.randomElement() else {
                        return Fail<[Snode], Error>(error: SnodeAPIError.insufficientSnodes)
                            .eraseToAnyPublisher()
                    }
                    
                    return Just(path)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                .eraseToAnyPublisher()
        }
    }

    internal static func dropGuardSnode(_ snode: Snode?) {
        guardSnodes.mutate { snodes in snodes = snodes.filter { $0 != snode } }
    }

    private static func drop(_ snode: Snode) throws {
        // We repair the path here because we can do it sync. In the case where we drop a whole
        // path we leave the re-building up to getPath(excluding:using:) because re-building the path
        // in that case is async.
        SnodeAPI.snodeFailureCount.mutate { $0[snode] = 0 }
        var oldPaths = paths
        guard let pathIndex = oldPaths.firstIndex(where: { $0.contains(snode) }) else { return }
        var path = oldPaths[pathIndex]
        guard let snodeIndex = path.firstIndex(of: snode) else { return }
        path.remove(at: snodeIndex)
        let unusedSnodes = SnodeAPI.snodePool.wrappedValue.subtracting(oldPaths.flatMap { $0 })
        guard !unusedSnodes.isEmpty else { throw SnodeAPIError.insufficientSnodes }
        // randomElement() uses the system's default random generator, which is cryptographically secure
        path.append(unusedSnodes.randomElement()!)
        // Don't test the new snode as this would reveal the user's IP
        oldPaths.remove(at: pathIndex)
        let newPaths = oldPaths + [ path ]
        paths = newPaths
        
        Storage.shared.write { db in
            SNLog("Persisting onion request paths to database.")
            try? newPaths.save(db)
        }
    }

    internal static func drop(_ path: [Snode]) {
        OnionRequestAPI.pathFailureCount.mutate { $0.removeValue(forKey: path) }
        var paths: [[Snode]] = OnionRequestAPI.paths
        guard let pathIndex = paths.firstIndex(of: path) else { return }
        paths.remove(at: pathIndex)
        OnionRequestAPI.paths = paths
        
        Storage.shared.write { db in
            guard !paths.isEmpty else {
                SNLog("Clearing onion request paths.")
                try? Snode.clearOnionRequestPaths(db)
                return
            }
            
            SNLog("Persisting onion request paths to database.")
            try? paths.save(db)
        }
    }

    fileprivate static func sendOnionRequest(
        with body: Data?,
        to destination: OnionRequestAPIDestination,
        swarmPublicKey: String?,
        timeout: TimeInterval,
        using dependencies: Dependencies
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        let snodeToExclude: Snode? = {
            switch destination {
                case .snode(let snode): return snode
                default: return nil
            }
        }()
        let ed25519SecretKey: [UInt8]? = Identity.fetchUserEd25519KeyPair()?.secretKey
        
        return getPath(excluding: snodeToExclude, ed25519SecretKey: ed25519SecretKey, using: dependencies)
            .tryFlatMap { path -> AnyPublisher<(ResponseInfoType, Data?), Error> in
                LibSession.sendOnionRequest(
                    to: destination,
                    body: body,
                    path: path,
                    swarmPublicKey: swarmPublicKey,
                    ed25519SecretKey: ed25519SecretKey,
                    using: dependencies
                )
            }
            .eraseToAnyPublisher()
    }
    
    // MARK: - Version Handling
    
    private static func generateV4Payload(for request: URLRequest) -> Data? {
        guard let url = request.url else { return nil }
        
        // Note: We need to remove the leading forward slash unless we are explicitly hitting
        // a legacy endpoint (in which case we need it to ensure the request signing works
        // correctly
        let endpoint: String = url.path
            .appending(url.query.map { value in "?\(value)" })
        
        let requestInfo: Network.RequestInfo = Network.RequestInfo(
            method: (request.httpMethod ?? "GET"),   // The default (if nil) is 'GET'
            endpoint: endpoint,
            headers: (request.allHTTPHeaderFields ?? [:])
                .setting(
                    "Content-Type",
                    (request.httpBody == nil ? nil :
                        // Default to JSON if not defined
                        ((request.allHTTPHeaderFields ?? [:])["Content-Type"] ?? "application/json")
                    )
                )
                .removingValue(forKey: "User-Agent")
        )
        
        /// Generate the Bencoded payload in the form `l{requestInfoLength}:{requestInfo}{bodyLength}:{body}e`
        guard let requestInfoData: Data = try? JSONEncoder().encode(requestInfo) else { return nil }
        guard let prefixData: Data = "l\(requestInfoData.count):".data(using: .ascii), let suffixData: Data = "e".data(using: .ascii) else {
            return nil
        }
        
        if let body: Data = request.httpBody, let bodyCountData: Data = "\(body.count):".data(using: .ascii) {
            return (prefixData + requestInfoData + bodyCountData + body + suffixData)
        }
        
        return (prefixData + requestInfoData + suffixData)
    }
}
