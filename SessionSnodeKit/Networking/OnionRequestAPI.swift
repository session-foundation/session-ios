// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import CryptoKit
import GRDB
import SessionUtilitiesKit

public extension Network.RequestType {
    static func onionRequest(_ payload: Data, to snode: Snode, timeout: TimeInterval = HTTP.defaultTimeout) -> Network.RequestType<Data?> {
        return Network.RequestType(
            id: "onionRequest",
            url: snode.address,
            method: "POST",
            body: payload,
            args: [payload, snode, timeout]
        ) { OnionRequestAPI.sendOnionRequest(payload, to: snode, timeout: timeout) }
    }
    
    static func onionRequest(_ request: URLRequest, to server: String, with x25519PublicKey: String, timeout: TimeInterval = HTTP.defaultTimeout) -> Network.RequestType<Data?> {
        return Network.RequestType(
            id: "onionRequest",
            url: request.url?.absoluteString,
            method: request.httpMethod,
            headers: request.allHTTPHeaderFields,
            body: request.httpBody,
            args: [request, server, x25519PublicKey, timeout]
        ) { OnionRequestAPI.sendOnionRequest(request, to: server, with: x25519PublicKey, timeout: timeout) }
    }
}

/// See the "Onion Requests" section of [The Session Whitepaper](https://arxiv.org/pdf/2002.04609.pdf) for more information.
public enum OnionRequestAPI {
    private static var buildPathsPublisher: Atomic<AnyPublisher<[[Snode]], Error>?> = Atomic(nil)
    private static var pathFailureCount: Atomic<[[Snode]: UInt]> = Atomic([:])
    private static var snodeFailureCount: Atomic<[Snode: UInt]> = Atomic([:])
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
    
    /// Tests the given snode. The returned promise errors out if the snode is faulty; the promise is fulfilled otherwise.
    private static func testSnode(_ snode: Snode, using dependencies: Dependencies) -> AnyPublisher<Void, Error> {
        let url = "\(snode.address):\(snode.port)/get_stats/v1"
        let timeout: TimeInterval = 3 // Use a shorter timeout for testing
        
        return HTTP.execute(.get, url, timeout: timeout)
            .decoded(as: SnodeAPI.GetStatsResponse.self, using: dependencies)
            .tryMap { response -> Void in
                guard let version: Version = response.version else { throw OnionRequestAPIError.missingSnodeVersion }
                guard version >= Version(major: 2, minor: 0, patch: 7) else {
                    SNLog("Unsupported snode version: \(version.stringValue).")
                    throw OnionRequestAPIError.unsupportedSnodeVersion(version.stringValue)
                }
                
                return ()
            }
            .eraseToAnyPublisher()
    }
    
    /// Finds `targetGuardSnodeCount` guard snodes to use for path building. The returned promise errors out with
    /// `Error.insufficientSnodes` if not enough (reliable) snodes are available.
    private static func getGuardSnodes(
        reusing reusableGuardSnodes: [Snode],
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
            return Fail(error: OnionRequestAPIError.insufficientSnodes)
                .eraseToAnyPublisher()
        }
        
        func getGuardSnode() -> AnyPublisher<Snode, Error> {
            // randomElement() uses the system's default random generator, which
            // is cryptographically secure
            guard let candidate = unusedSnodes.randomElement() else {
                return Fail(error: OnionRequestAPIError.insufficientSnodes)
                    .eraseToAnyPublisher()
            }
            
            unusedSnodes.remove(candidate) // All used snodes should be unique
            SNLog("Testing guard snode: \(candidate).")
            
            // Loop until a reliable guard snode is found
            return testSnode(candidate, using: dependencies)
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
            let publisher: AnyPublisher<[[Snode]], Error> = getGuardSnodes(reusing: reusableGuardSnodes, using: dependencies)
                .flatMap { (guardSnodes: Set<Snode>) -> AnyPublisher<[[Snode]], Error> in
                    var unusedSnodes: Set<Snode> = SnodeAPI.snodePool.wrappedValue
                        .subtracting(guardSnodes)
                        .subtracting(reusablePaths.flatMap { $0 })
                    let reusableGuardSnodeCount: UInt = UInt(reusableGuardSnodes.count)
                    let pathSnodeCount: UInt = (targetGuardSnodeCount - reusableGuardSnodeCount) * pathSize - (targetGuardSnodeCount - reusableGuardSnodeCount)
                    
                    guard unusedSnodes.count >= pathSnodeCount else {
                        return Fail<[[Snode]], Error>(error: OnionRequestAPIError.insufficientSnodes)
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
                    buildPaths(reusing: paths, using: dependencies) // Re-build paths in the background
                        .subscribe(on: DispatchQueue.global(qos: .background))
                        .sink(receiveCompletion: { _ in cancellable = [] }, receiveValue: { _ in })
                        .store(in: &cancellable)
                    
                    return Just(path)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                else {
                    return buildPaths(reusing: paths, using: dependencies)
                        .flatMap { paths in
                            guard let path: [Snode] = paths.filter({ !$0.contains(snode) }).randomElement() else {
                                return Fail<[Snode], Error>(error: OnionRequestAPIError.insufficientSnodes)
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
                buildPaths(reusing: paths, using: dependencies) // Re-build paths in the background
                    .subscribe(on: DispatchQueue.global(qos: .background))
                    .sink(receiveCompletion: { _ in cancellable = [] }, receiveValue: { _ in })
                    .store(in: &cancellable)
                
                guard let path: [Snode] = paths.randomElement() else {
                    return Fail<[Snode], Error>(error: OnionRequestAPIError.insufficientSnodes)
                        .eraseToAnyPublisher()
                }
                
                return Just(path)
                    .setFailureType(to: Error.self)
                    .eraseToAnyPublisher()
            }
        }
        else {
            return buildPaths(reusing: [], using: dependencies)
                .flatMap { paths in
                    if let snode = snode {
                        if let path = paths.filter({ !$0.contains(snode) }).randomElement() {
                            return Just(path)
                                .setFailureType(to: Error.self)
                                .eraseToAnyPublisher()
                        }
                        
                        return Fail<[Snode], Error>(error: OnionRequestAPIError.insufficientSnodes)
                            .eraseToAnyPublisher()
                    }
                    
                    guard let path: [Snode] = paths.randomElement() else {
                        return Fail<[Snode], Error>(error: OnionRequestAPIError.insufficientSnodes)
                            .eraseToAnyPublisher()
                    }
                    
                    return Just(path)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                .eraseToAnyPublisher()
        }
    }

    private static func dropGuardSnode(_ snode: Snode) {
        guardSnodes.mutate { snodes in snodes = snodes.filter { $0 != snode } }
    }

    private static func drop(_ snode: Snode) throws {
        // We repair the path here because we can do it sync. In the case where we drop a whole
        // path we leave the re-building up to getPath(excluding:using:) because re-building the path
        // in that case is async.
        OnionRequestAPI.snodeFailureCount.mutate { $0[snode] = 0 }
        var oldPaths = paths
        guard let pathIndex = oldPaths.firstIndex(where: { $0.contains(snode) }) else { return }
        var path = oldPaths[pathIndex]
        guard let snodeIndex = path.firstIndex(of: snode) else { return }
        path.remove(at: snodeIndex)
        let unusedSnodes = SnodeAPI.snodePool.wrappedValue.subtracting(oldPaths.flatMap { $0 })
        guard !unusedSnodes.isEmpty else { throw OnionRequestAPIError.insufficientSnodes }
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

    private static func drop(_ path: [Snode]) {
        OnionRequestAPI.pathFailureCount.mutate { $0[path] = 0 }
        var paths = OnionRequestAPI.paths
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
    
    /// Builds an onion around `payload` and returns the result.
    private static func buildOnion(
        around payload: Data,
        targetedAt destination: OnionRequestAPIDestination,
        using dependencies: Dependencies
    ) -> AnyPublisher<OnionBuildingResult, Error> {
        var guardSnode: Snode!
        var targetSnodeSymmetricKey: Data! // Needed by invoke(_:on:with:) to decrypt the response sent back by the destination
        var encryptionResult: AES.GCM.EncryptionResult!
        var snodeToExclude: Snode?
        
        if case .snode(let snode) = destination { snodeToExclude = snode }
        
        return getPath(excluding: snodeToExclude, using: dependencies)
            .flatMap { path -> AnyPublisher<AES.GCM.EncryptionResult, Error> in
                guardSnode = path.first!
                
                // Encrypt in reverse order, i.e. the destination first
                return encrypt(payload, for: destination)
                    .flatMap { r -> AnyPublisher<AES.GCM.EncryptionResult, Error> in
                        targetSnodeSymmetricKey = r.symmetricKey
                        
                        // Recursively encrypt the layers of the onion (again in reverse order)
                        encryptionResult = r
                        var path = path
                        var rhs = destination
                        
                        func addLayer() -> AnyPublisher<AES.GCM.EncryptionResult, Error> {
                            guard !path.isEmpty else {
                                return Just(encryptionResult)
                                    .setFailureType(to: Error.self)
                                    .eraseToAnyPublisher()
                            }
                            
                            let lhs = OnionRequestAPIDestination.snode(path.removeLast())
                            return OnionRequestAPI
                                .encryptHop(from: lhs, to: rhs, using: encryptionResult)
                                .flatMap { r -> AnyPublisher<AES.GCM.EncryptionResult, Error> in
                                    encryptionResult = r
                                    rhs = lhs
                                    return addLayer()
                                }
                                .eraseToAnyPublisher()
                        }
                        
                        return addLayer()
                    }
                    .eraseToAnyPublisher()
            }
            .map { _ in (guardSnode, encryptionResult, targetSnodeSymmetricKey) }
            .eraseToAnyPublisher()
    }

    // MARK: - Public API
    
    /// Sends an onion request to `snode`. Builds new paths as needed.
    public static func sendOnionRequest(
        _ payload: Data,
        to snode: Snode,
        timeout: TimeInterval = HTTP.defaultTimeout
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        /// **Note:** Currently the service nodes only support V3 Onion Requests
        return sendOnionRequest(
            with: payload,
            to: OnionRequestAPIDestination.snode(snode),
            version: .v3,
            timeout: timeout
        )
    }
    
    /// Sends an onion request to `server`. Builds new paths as needed.
    public static func sendOnionRequest(
        _ request: URLRequest,
        to server: String,
        with x25519PublicKey: String,
        timeout: TimeInterval = HTTP.defaultTimeout
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        guard let url = request.url, let host = request.url?.host else {
            return Fail(error: OnionRequestAPIError.invalidURL)
                .eraseToAnyPublisher()
        }
        
        let scheme: String? = url.scheme
        let port: UInt16? = url.port.map { UInt16($0) }
        
        guard let payload: Data = generateV4Payload(for: request) else {
            return Fail(error: OnionRequestAPIError.invalidRequestInfo)
                .eraseToAnyPublisher()
        }
        
        return OnionRequestAPI
            .sendOnionRequest(
                with: payload,
                to: OnionRequestAPIDestination.server(
                    host: host,
                    target: OnionRequestAPIVersion.v4.rawValue,
                    x25519PublicKey: x25519PublicKey,
                    scheme: scheme,
                    port: port
                ),
                version: .v4,
                timeout: timeout
            )
            .handleEvents(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            SNLog("Couldn't reach server: \(url) due to error: \(error).")
                    }
                }
            )
            .eraseToAnyPublisher()
    }
    
    public static func sendOnionRequest(
        with payload: Data,
        to destination: OnionRequestAPIDestination,
        version: OnionRequestAPIVersion,
        timeout: TimeInterval = HTTP.defaultTimeout,
        using dependencies: Dependencies = Dependencies()
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        var guardSnode: Snode?
        
        return buildOnion(around: payload, targetedAt: destination, using: dependencies)
            .flatMap { intermediate -> AnyPublisher<(ResponseInfoType, Data?), Error> in
                guardSnode = intermediate.guardSnode
                let url = "\(guardSnode!.address):\(guardSnode!.port)/onion_req/v2"
                let finalEncryptionResult = intermediate.finalEncryptionResult
                let onion = finalEncryptionResult.ciphertext
                if case OnionRequestAPIDestination.server = destination, Double(onion.count) > 0.75 * Double(maxRequestSize) {
                    SNLog("Approaching request size limit: ~\(onion.count) bytes.")
                }
                let parameters: JSON = [
                    "ephemeral_key" : finalEncryptionResult.ephemeralPublicKey.toHexString()
                ]
                let destinationSymmetricKey = intermediate.destinationSymmetricKey
                
                // TODO: Replace 'json' with a codable typed
                return encode(ciphertext: onion, json: parameters)
                    .flatMap { body in HTTP.execute(.post, url, body: body, timeout: timeout) }
                    .flatMap { responseData in
                        handleResponse(
                            responseData: responseData,
                            destinationSymmetricKey: destinationSymmetricKey,
                            version: version,
                            destination: destination
                        )
                    }
                    .eraseToAnyPublisher()
            }
            .handleEvents(
                receiveCompletion: { result in
                    switch result {
                        case .finished: break
                        case .failure(let error):
                            guard
                                case HTTPError.httpRequestFailed(let statusCode, let data) = error,
                                let guardSnode: Snode = guardSnode
                            else { return }
                            
                            let path = paths.first { $0.contains(guardSnode) }
                            
                            func handleUnspecificError() {
                                guard let path = path else { return }
                                
                                var pathFailureCount: UInt = (OnionRequestAPI.pathFailureCount.wrappedValue[path] ?? 0)
                                pathFailureCount += 1
                                
                                if pathFailureCount >= pathFailureThreshold {
                                    dropGuardSnode(guardSnode)
                                    path.forEach { snode in
                                        SnodeAPI.handleError(withStatusCode: statusCode, data: data, forSnode: snode) // Intentionally don't throw
                                    }
                                    
                                    drop(path)
                                }
                                else {
                                    OnionRequestAPI.pathFailureCount.mutate { $0[path] = pathFailureCount }
                                }
                            }
                            
                            let prefix = "Next node not found: "
                            let json: JSON?
                            
                            if let data: Data = data, let processedJson = try? JSONSerialization.jsonObject(with: data, options: [ .fragmentsAllowed ]) as? JSON {
                                json = processedJson
                            }
                            else if let data: Data = data, let result: String = String(data: data, encoding: .utf8) {
                                json = [ "result": result ]
                            }
                            else {
                                json = nil
                            }
                            
                            if let message = json?["result"] as? String, message.hasPrefix(prefix) {
                                let ed25519PublicKey = message[message.index(message.startIndex, offsetBy: prefix.count)..<message.endIndex]
                                
                                if let path = path, let snode = path.first(where: { $0.ed25519PublicKey == ed25519PublicKey }) {
                                    var snodeFailureCount: UInt = (OnionRequestAPI.snodeFailureCount.wrappedValue[snode] ?? 0)
                                    snodeFailureCount += 1
                                    
                                    if snodeFailureCount >= snodeFailureThreshold {
                                        SnodeAPI.handleError(withStatusCode: statusCode, data: data, forSnode: snode) // Intentionally don't throw
                                        do {
                                            try drop(snode)
                                        }
                                        catch {
                                            handleUnspecificError()
                                        }
                                    }
                                    else {
                                        OnionRequestAPI.snodeFailureCount
                                            .mutate { $0[snode] = snodeFailureCount }
                                    }
                                } else {
                                    // Do nothing
                                }
                            }
                            else if let message = json?["result"] as? String, message == "Loki Server error" {
                                // Do nothing
                            }
                            else if case .server(let host, _, _, _, _) = destination, host == "116.203.70.33" && statusCode == 0 {
                                // FIXME: Temporary thing to kick out nodes that can't talk to the V2 OGS yet
                                handleUnspecificError()
                            }
                            else if statusCode == 0 { // Timeout
                                // Do nothing
                            }
                            else {
                                handleUnspecificError()
                            }
                    }
                }
            )
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
        
        let requestInfo: HTTP.RequestInfo = HTTP.RequestInfo(
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
    
    private static func handleResponse(
        responseData: Data,
        destinationSymmetricKey: Data,
        version: OnionRequestAPIVersion,
        destination: OnionRequestAPIDestination
    ) -> AnyPublisher<(ResponseInfoType, Data?), Error> {
        switch version {
            // V2 and V3 Onion Requests have the same structure for responses
            case .v2, .v3:
                let json: JSON
                
                if let processedJson = try? JSONSerialization.jsonObject(with: responseData, options: [ .fragmentsAllowed ]) as? JSON {
                    json = processedJson
                }
                else if let result: String = String(data: responseData, encoding: .utf8) {
                    json = [ "result": result ]
                }
                else {
                    return Fail(error: HTTPError.invalidJSON)
                        .eraseToAnyPublisher()
                }
                
                guard let base64EncodedIVAndCiphertext = json["result"] as? String, let ivAndCiphertext = Data(base64Encoded: base64EncodedIVAndCiphertext), ivAndCiphertext.count >= AES.GCM.ivSize else {
                    return Fail(error: HTTPError.invalidJSON)
                        .eraseToAnyPublisher()
                }
                
                do {
                    let data = try AES.GCM.decrypt(ivAndCiphertext, with: destinationSymmetricKey)
                    
                    guard let json = try JSONSerialization.jsonObject(with: data, options: [ .fragmentsAllowed ]) as? JSON, let statusCode = json["status_code"] as? Int ?? json["status"] as? Int else {
                        return Fail(error: HTTPError.invalidJSON)
                            .eraseToAnyPublisher()
                    }
                    
                    if statusCode == 406 { // Clock out of sync
                        SNLog("The user's clock is out of sync with the service node network.")
                        return Fail(error: SnodeAPIError.clockOutOfSync)
                            .eraseToAnyPublisher()
                    }
                    
                    if statusCode == 401 { // Signature verification failed
                        SNLog("Failed to verify the signature.")
                        return Fail(error: SnodeAPIError.signatureVerificationFailed)
                            .eraseToAnyPublisher()
                    }
                    
                    if let bodyAsString = json["body"] as? String {
                        guard let bodyAsData = bodyAsString.data(using: .utf8) else {
                            return Fail(error: HTTPError.invalidResponse)
                                .eraseToAnyPublisher()
                        }
                        guard let body = try? JSONSerialization.jsonObject(with: bodyAsData, options: [ .fragmentsAllowed ]) as? JSON else {
                            return Fail(
                                error: OnionRequestAPIError.httpRequestFailedAtDestination(
                                    statusCode: UInt(statusCode),
                                    data: bodyAsData,
                                    destination: destination
                                )
                            ).eraseToAnyPublisher()
                        }
                        
                        if let timestamp = body["t"] as? Int64 {
                            let offset = timestamp - Int64(floor(Date().timeIntervalSince1970 * 1000))
                            SnodeAPI.clockOffsetMs.mutate { $0 = offset }
                        }
                        
                        guard 200...299 ~= statusCode else {
                            return Fail(
                                error: OnionRequestAPIError.httpRequestFailedAtDestination(
                                    statusCode: UInt(statusCode),
                                    data: bodyAsData,
                                    destination: destination
                                )
                            ).eraseToAnyPublisher()
                        }
                        
                        return Just((HTTP.ResponseInfo(code: statusCode, headers: [:]), bodyAsData))
                            .setFailureType(to: Error.self)
                            .eraseToAnyPublisher()
                    }
                    
                    guard 200...299 ~= statusCode else {
                        return Fail(
                            error: OnionRequestAPIError.httpRequestFailedAtDestination(
                                statusCode: UInt(statusCode),
                                data: data,
                                destination: destination
                            )
                        ).eraseToAnyPublisher()
                    }
                    
                    return Just((HTTP.ResponseInfo(code: statusCode, headers: [:]), data))
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                catch {
                    return Fail(error: error)
                        .eraseToAnyPublisher()
                }
                
            // V4 Onion Requests have a very different structure for responses
            case .v4:
                guard responseData.count >= AES.GCM.ivSize else {
                    return Fail(error: HTTPError.invalidResponse)
                        .eraseToAnyPublisher()
                }
                
                do {
                    let data: Data = try AES.GCM.decrypt(responseData, with: destinationSymmetricKey)
                    
                    // Process the bencoded response
                    guard let processedResponse: (info: ResponseInfoType, body: Data?) = process(bencodedData: data) else {
                        return Fail(error: HTTPError.invalidResponse)
                            .eraseToAnyPublisher()
                    }
                    
                    // Custom handle a clock out of sync error (v4 returns '425' but included the '406'
                    // just in case)
                    guard processedResponse.info.code != 406 && processedResponse.info.code != 425 else {
                        SNLog("The user's clock is out of sync with the service node network.")
                        return Fail(error: SnodeAPIError.clockOutOfSync)
                            .eraseToAnyPublisher()
                    }
                    
                    guard processedResponse.info.code != 401 else { // Signature verification failed
                        SNLog("Failed to verify the signature.")
                        return Fail(error: SnodeAPIError.signatureVerificationFailed)
                            .eraseToAnyPublisher()
                    }
                    
                    // Handle error status codes
                    guard 200...299 ~= processedResponse.info.code else {
                        return Fail(error: OnionRequestAPIError.httpRequestFailedAtDestination(
                            statusCode: UInt(processedResponse.info.code),
                            data: data,
                            destination: destination
                        )).eraseToAnyPublisher()
                    }
                    
                    return Just(processedResponse)
                        .setFailureType(to: Error.self)
                        .eraseToAnyPublisher()
                }
                catch {
                    return Fail(error: error)
                        .eraseToAnyPublisher()
                }
        }
    }
    
    public static func process(bencodedData data: Data) -> (info: ResponseInfoType, body: Data?)? {
        // The data will be in the form of `l123:jsone` or `l123:json456:bodye` so we need to break
        // the data into parts to properly process it
        guard let responseString: String = String(data: data, encoding: .ascii), responseString.starts(with: "l") else {
            return nil
        }
        
        let stringParts: [String.SubSequence] = responseString.split(separator: ":")
        
        guard stringParts.count > 1, let infoLength: Int = Int(stringParts[0].suffix(from: stringParts[0].index(stringParts[0].startIndex, offsetBy: 1))) else {
            return nil
        }
        
        let infoStringStartIndex: String.Index = responseString.index(responseString.startIndex, offsetBy: "l\(infoLength):".count)
        let infoStringEndIndex: String.Index = responseString.index(infoStringStartIndex, offsetBy: infoLength)
        let infoString: String = String(responseString[infoStringStartIndex..<infoStringEndIndex])

        guard let infoStringData: Data = infoString.data(using: .utf8), let responseInfo: HTTP.ResponseInfo = try? JSONDecoder().decode(HTTP.ResponseInfo.self, from: infoStringData) else {
            return nil
        }

        // Custom handle a clock out of sync error (v4 returns '425' but included the '406' just
        // in case)
        guard responseInfo.code != 406 && responseInfo.code != 425 else { return nil }
        guard responseInfo.code != 401 else { return nil }
        
        // If there is no data in the response then just return the ResponseInfo
        guard responseString.count > "l\(infoLength)\(infoString)e".count else {
            return (responseInfo, nil)
        }
        
        // Extract the response data as well
        let dataString: String = String(responseString.suffix(from: infoStringEndIndex))
        let dataStringParts: [String.SubSequence] = dataString.split(separator: ":")
        
        guard dataStringParts.count > 1, let finalDataLength: Int = Int(dataStringParts[0]), let suffixData: Data = "e".data(using: .utf8) else {
            return nil
        }
        
        let dataBytes: Array<UInt8> = Array(data)
        let dataEndIndex: Int = (dataBytes.count - suffixData.count)
        let dataStartIndex: Int = (dataEndIndex - finalDataLength)
        let finalDataBytes: ArraySlice<UInt8> = dataBytes[dataStartIndex..<dataEndIndex]
        let finalData: Data = Data(finalDataBytes)
        
        return (responseInfo, finalData)
    }
}
