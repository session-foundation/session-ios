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
    internal static var pathFailureCount: Atomic<[[Snode]: UInt]> = Atomic([:])
    internal static var guardSnodes: Atomic<Set<Snode>> = Atomic([])
    
    // Not a set to ensure we consistently show the same path to the user
    private static var _paths: Atomic<[[Snode]]?> = Atomic(nil)
    public static var paths: [[Snode]] {
        get {
            if let paths: [[Snode]] = _paths.wrappedValue { return paths }
            
            let results: [[Snode]]? = Storage.shared.read { db in
                try? Snode.fetchAllOnionRequestPaths(db)
            }
            
            if results?.isEmpty == false {
                _paths.mutate {
                    $0 = results
                    results?.forEach { LibSession.addPath(path: $0) }
                }
            }
            return (results ?? [])
        }
        set {
            _paths.mutate {
                $0 = newValue
                newValue.forEach { LibSession.addPath(path: $0) }
            }
        }
    }

    // MARK: - Settings
    
    public static let maxRequestSize = 10_000_000 // 10 MB
    /// The number of snodes (including the guard snode) in a path.
    internal static let pathSize: Int = 3
    /// The number of times a path can fail before it's replaced.
    private static let pathFailureThreshold: UInt = 3
    /// The number of times a snode can fail before it's replaced.
    private static let snodeFailureThreshold: UInt = 3
    
    // MARK: - Onion Building Result
    
    private typealias OnionBuildingResult = (guardSnode: Snode, finalEncryptionResult: AES.GCM.EncryptionResult, destinationSymmetricKey: Data)

    // MARK: - Private API

    internal static func dropGuardSnode(_ snode: Snode?) {
        guardSnodes.mutate { snodes in snodes = snodes.filter { $0 != snode } }
    }

    private static func drop(_ snode: Snode) throws {
        // We repair the path here because we can do it sync. In the case where we drop a whole
        // path we leave the re-building up to the `BuildPathsJob` because re-building the path
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
        
        return BuildPathsJob
            .runIfNeeded(
                excluding: snodeToExclude,
                ed25519SecretKey: ed25519SecretKey,
                using: dependencies
            )
            .tryFlatMap { _ -> AnyPublisher<(ResponseInfoType, Data?), Error> in
                LibSession.sendOnionRequest(
                    to: destination,
                    body: body,
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
