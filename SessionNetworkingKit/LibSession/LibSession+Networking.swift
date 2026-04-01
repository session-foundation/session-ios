// Copyright © 2024 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import Combine
import SessionUtil
import SessionUtilitiesKit

// MARK: - Log.Category

public extension Log.Category {
    static let network: Log.Category = .create("Network", defaultLevel: .info)
}

// MARK: - LibSessionNetwork

public actor LibSessionNetwork: NetworkType {
    fileprivate enum LibSessionNetworkError: Int {
        case suspended = -10002
        case invalidDownloadUrl = -10007
        case requestCancelled = -10200
    }
    
    fileprivate typealias Response = (
        success: Bool,
        timeout: Bool,
        statusCode: Int,
        headers: [String: String],
        data: Data?
    )
    
    internal static var snodeCachePath: String { "\(SessionFileManager.nonInjectedAppSharedDataDirectoryPath)/snodeCache" }
    
    private unowned let dependencies: Dependencies
    private var context: Context!
    private var contextPtr: UnsafeMutableRawPointer!
    private var initTask: Task<Void, Never>?
    private var network: UnsafeMutablePointer<network_object>? = nil
    nonisolated private let internalNetworkStatus: CurrentValueAsyncStream<NetworkStatus> = CurrentValueAsyncStream(.unknown)
    private let customCachePath: String?
    
    public private(set) var isSuspended: Bool = false
    public var hardfork: Int {
        get async {
            guard let network = try? await getOrCreateNetwork() else { return 0 }
            
            return Int(session_network_hardfork(network))
        }
    }
    public var softfork: Int {
        get async {
            guard let network = try? await getOrCreateNetwork() else { return 0 }
            
            return Int(session_network_softfork(network))
        }
    }
    public var hasRetrievedNetworkTimeOffset: Bool {
        get async {
            guard let network = try? await getOrCreateNetwork() else { return false }
            
            return session_network_has_retrieved_time_offset(network)
        }
    }
    public var networkTimeOffsetMs: Int64 {
        get async {
            guard let network = try? await getOrCreateNetwork() else { return 0 }
            
            return Int64(session_network_time_offset(network))
        }
    }
    
    nonisolated public var networkStatus: AsyncStream<NetworkStatus> { internalNetworkStatus.stream }
    nonisolated public let syncState: NetworkSyncState
    
    // MARK: - Initialization
    
    public init(
        customCachePath: String? = nil,
        using dependencies: Dependencies
    ) {
        self.dependencies = dependencies
        self.customCachePath = customCachePath
        self.syncState = NetworkSyncState(
            hardfork: dependencies[defaults: .standard, key: .hardfork],
            softfork: dependencies[defaults: .standard, key: .hardfork],
            using: dependencies
        )
        
        /// Create the network object
        self.initTask = Task { [weak self] in
            guard let self else { return }
            guard !Task.isCancelled else { return }
            
            /// If the app has been set to `forceOffline` then we need to explicitly set the network status to disconnected (because
            /// it'll never be set otherwise)
            if dependencies[feature: .forceOffline] {
                await setNetworkStatus(status: .disconnected)
            }
            
            /// Create the `network` instance so it can do any setup required (actor isolation will prevent multiple instances from
            /// being created at once)
            _ = try? await getOrCreateNetwork()
        }
        
        /// Now that we have finished construction we need to set the `context` and `contextPtr` values to something
        self.context = Context(network: self)
        self.contextPtr = Unmanaged.passRetained(context).toOpaque()
    }
    
    deinit {
        initTask?.cancel()
        
        /// Send completion events to the observables (so they can resubscribe to a future instance)
        Task { [status = internalNetworkStatus] in
            await status.send(.disconnected)
            await status.finishCurrentStreams()
        }
        
        /// Cleanup the resources we used
        LibSessionNetwork.cleanupResources(
            network: network,
            contextPtr: contextPtr
        )
    }
    
    private static func cleanupResources(
        network: UnsafeMutablePointer<network_object>?,
        contextPtr: UnsafeMutableRawPointer?
    ) {
        /// Clear the network changed callbacks (just in case, since we are going to free the `dependenciesPtr`) and then free the
        /// network object
        switch network {
            case .none: break
            case .some(let network):
                session_network_set_status_changed_callback(network, nil, nil)
                session_network_set_network_info_changed_callback(network, nil, nil)
                session_network_free(network)
        }
        
        /// Finally we need to make sure to clean up the unbalanced retain to the dependencies
        if let ptr = contextPtr {
            Unmanaged<Context>.fromOpaque(ptr).release()
        }
    }
    
    // MARK: - NetworkType

    public func getActivePaths() async throws -> [LibSession.Path] {
        let network = try await getOrCreateNetwork()
        
        var cPathsPtr: UnsafeMutablePointer<session_path_info>?
        var cPathsLen: Int = 0
        session_network_get_active_paths(network, &cPathsPtr, &cPathsLen)
        defer {
            if let paths = cPathsPtr {
                session_network_paths_free(paths)
            }
        }
        
        guard
            cPathsLen > 0,
            let cPaths: UnsafeMutablePointer<session_path_info> = cPathsPtr
        else { return [] }
        
        return (0..<cPathsLen).map { index in
            var nodes: [LibSession.Snode] = []
            var category: Network.PathCategory?
            var destinationPubkey: String?
            var destinationAddress: String?
            
            if cPaths[index].nodes_count > 0, let cNodes: UnsafePointer<network_service_node> = cPaths[index].nodes {
                nodes = (0..<cPaths[index].nodes_count).map { LibSession.Snode(cNodes[$0]) }
            }
            
            if let onionMeta: UnsafePointer<session_onion_path_metadata> = cPaths[index].onion_metadata {
                category = Network.PathCategory(onionMeta.get(\.category))
            }
            else if let sessionRouterMeta: UnsafePointer<session_router_tunnel_metadata> = cPaths[index].session_router_metadata {
                destinationPubkey = sessionRouterMeta.get(\.destination_pubkey)
                destinationAddress = sessionRouterMeta.get(\.destination_snode_address)
            }
            
            return LibSession.Path(
                nodes: nodes,
                category: category,
                destinationPubkey: destinationPubkey,
                destinationSnodeAddress: destinationAddress
            )
        }
    }
    
    public func getSwarm(for swarmPublicKey: String, ignoreStrikeCount: Bool) async throws -> Set<LibSession.Snode> {
        typealias Result = Set<LibSession.Snode>
        
        let network = try await getOrCreateNetwork()
        let sessionId: SessionId = try SessionId(from: swarmPublicKey)
        
        guard let cSwarmPublicKey: [CChar] = sessionId.publicKeyString.cString(using: .utf8) else {
            throw LibSessionError.invalidCConversion
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            let context = LibSessionNetwork.ContinuationBox(continuation).unsafePointer()
            
            session_network_get_swarm(network, cSwarmPublicKey, ignoreStrikeCount, { swarmPtr, swarmSize, ctx in
                guard let box = LibSessionNetwork.ContinuationBox<Result>.from(unsafePointer: ctx) else {
                    return
                }
                
                guard
                    swarmSize > 0,
                    let cSwarm: UnsafeMutablePointer<network_service_node> = swarmPtr
                else { return box.resumeOnce(throwing: StorageServerError.unableToRetrieveSwarm) }
                
                var nodes: Set<LibSession.Snode> = []
                (0..<swarmSize).forEach { index in nodes.insert(LibSession.Snode(cSwarm[index])) }
                box.resumeOnce(returning: nodes)
            }, context)
        }
    }
    
    public func getRandomNodes(count: Int) async throws -> Set<LibSession.Snode> {
        typealias Result = Set<LibSession.Snode>
        
        let network = try await getOrCreateNetwork()
        
        let nodes: Set<LibSession.Snode> = try await withCheckedThrowingContinuation { continuation in
            let context = LibSessionNetwork.ContinuationBox(continuation).unsafePointer()
            
            session_network_get_random_nodes(network, UInt16(count), { nodesPtr, nodesSize, ctx in
                guard let box = LibSessionNetwork.ContinuationBox<Result>.from(unsafePointer: ctx) else {
                    return
                }
                
                guard
                    nodesSize > 0,
                    let cSwarm: UnsafeMutablePointer<network_service_node> = nodesPtr
                else { return box.resumeOnce(throwing: StorageServerError.unableToRetrieveSwarm) }
                
                var nodes: Set<LibSession.Snode> = []
                (0..<nodesSize).forEach { index in nodes.insert(LibSession.Snode(cSwarm[index])) }
                box.resumeOnce(returning: nodes)
            }, context);
        }
        
        guard nodes.count >= count else {
            throw StorageServerError.unableToRetrieveSwarm
        }
        
        return nodes
    }
    
    public func send<E: EndpointType>(
        endpoint: E,
        destination: Network.Destination,
        body: Data?,
        category: Network.RequestCategory,
        requestTimeout: TimeInterval,
        overallTimeout: TimeInterval?
    ) async throws -> (info: ResponseInfoType, value: Data?) {
        try Task.checkCancellation()
        
        switch destination {
            case .snode, .server, .serverUpload:
                return try await sendRequest(
                    endpoint: endpoint,
                    destination: destination,
                    body: body,
                    category: category,
                    requestTimeout: requestTimeout,
                    overallTimeout: overallTimeout
                )
                
            case .randomSnode(let swarmPublicKey):
                guard body != nil else { throw NetworkError.invalidRequest }
                
                let swarm: Set<LibSession.Snode> = try await getSwarm(
                    for: swarmPublicKey,
                    ignoreStrikeCount: false
                )
                let swarmDrainer: SwarmDrainer = SwarmDrainer(swarm: swarm, using: dependencies)
                try Task.checkCancellation()
                
                let snode: LibSession.Snode = try await swarmDrainer.selectNextNode()
                try Task.checkCancellation()
                
                return try await self.sendRequest(
                    endpoint: endpoint,
                    destination: .snode(snode, swarmPublicKey: swarmPublicKey),
                    body: body,
                    category: category,
                    requestTimeout: requestTimeout,
                    overallTimeout: overallTimeout
                )
        }
    }
    
    public func upload(
        fileURL: URL,
        fileName: String?,
        stallTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        overallTimeout: TimeInterval?,
        desiredPathIndex: UInt8?
    ) async throws -> FileMetadata {
        try Task.checkCancellation()
        
        let network = try await getOrCreateNetwork()
        try Task.checkCancellation()
        
        let customTTL: UInt64 = (dependencies[feature: .shortenFileTTL] ? 60 : 0)
        let handleBox: RequestHandleBox = RequestHandleBox(nil)
        let context: StreamingUploadContext = try StreamingUploadContext(
            fileURL: fileURL,
            using: dependencies
        )
        let contextPtr: UnsafeMutableRawPointer = Unmanaged.passRetained(context).toOpaque()
        let metadata: FileMetadata = try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    context.setContinuation(continuation)
                    
                    var callbacks = session_upload_callbacks(
                        next_data: { buffer, capacity, ctx in
                            guard
                                let ctx,
                                let buffer,
                                capacity > 0
                            else { return 0 }
                            
                            let context = Unmanaged<StreamingUploadContext>
                                .fromOpaque(ctx)
                                .takeUnretainedValue()
                            
                            guard let fileHandle: (any FileHandleType) = context.fileHandle else {
                                return -1 /// Signal error to C++ side
                            }
                            
                            /// It seems like the `FileHandle` can inconsistently throw, return an empty `Data` or return
                            /// `nil` when it hits EOF so we need to try to handle this inconsistent behaviour
                            do {
                                guard
                                    let data: Data = try fileHandle.read(upToCount: capacity),
                                    !data.isEmpty
                                else { return 0 }
                                
                                data.withUnsafeBytes { dataPtr in
                                    buffer.update(
                                        from: dataPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                        count: data.count
                                    )
                                }
                                
                                context.bytesRead += Int64(data.count)
                                return data.count
                            }
                            catch {
                                /// If the `bytesRead` seems to match (or be greater than) the `expectedFileSize` then
                                /// we've probably hit EOF and the `FileHandle` is just confused so just consider it a success
                                guard
                                    context.expectedFileSize >= 0,
                                    context.bytesRead >= context.expectedFileSize
                                else { return -1 }
                                
                                return 0
                            }
                        },
                        on_complete: { metadata, statusCode, timeout, ctx in
                            guard let ctx: UnsafeMutableRawPointer = ctx else { return }
                            defer { Unmanaged<StreamingUploadContext>.fromOpaque(ctx).release() }
                            
                            let context: StreamingUploadContext = Unmanaged<StreamingUploadContext>
                                .fromOpaque(ctx)
                                .takeUnretainedValue()
                            
                            try? context.fileHandle?.close()
                            
                            if let metadata: session_file_metadata = metadata?.pointee {
                                context.resumeOnce(returning: FileMetadata(metadata))
                                return
                            }
                            
                            do {
                                try LibSessionNetwork.throwErrorIfNeeded((false, timeout, Int(statusCode), [:], nil))
                                throw NetworkError.invalidResponse
                            }
                            catch { context.resumeOnce(throwing: error) }
                        },
                        ctx: contextPtr
                    )
                    
                    let handle: OpaquePointer?
                    
                    switch fileName?.cString(using: .utf8) {
                        case .some(let fileNameCString):
                            handle = fileNameCString.withUnsafeBufferPointer { namePtr in
                                withUnsafePointer(to: &callbacks) { callbacksPtr in
                                    session_network_upload(
                                        network,
                                        namePtr.baseAddress,
                                        customTTL,
                                        callbacksPtr,
                                        Int64(stallTimeout * 1000),
                                        Int64(requestTimeout * 1000),
                                        overallTimeout.map { Int64($0 * 1000) } ?? 0,
                                        (desiredPathIndex.map { Int8($0) } ?? -1)
                                    )
                                }
                            }
                            
                        case .none:
                            handle = withUnsafePointer(to: &callbacks) { callbacksPtr in
                                session_network_upload(
                                    network,
                                    nil,
                                    customTTL,
                                    callbacksPtr,
                                    Int64(stallTimeout * 1000),
                                    Int64(requestTimeout * 1000),
                                    overallTimeout.map { Int64($0 * 1000) } ?? 0,
                                    (desiredPathIndex.map { Int8($0) } ?? -1)
                                )
                            }
                    }
                    
                    guard let handle else {
                        context.resumeOnce(throwing: NetworkError.invalidRequest)
                        Unmanaged<StreamingUploadContext>.fromOpaque(contextPtr).release()
                        return
                    }
                    
                    /// Store for cancellation, `StreamingUploadContext` will be released via
                    /// `onSuccess`/`onError`
                    handleBox.handle = handle
                }
            },
            onCancel: {
                context.resumeOnce(throwing: CancellationError())
                
                if let handle: OpaquePointer = handleBox.handle {
                    handleBox.handle = nil
                    session_network_upload_cancel(handle)
                    session_network_upload_free(handle)
                }
            }
        )
        
        if let handle: OpaquePointer = handleBox.handle {
            handleBox.handle = nil
            session_network_upload_free(handle)
        }
        
        return metadata
    }
    
    public func download(
        downloadUrl: String,
        stallTimeout: TimeInterval,
        requestTimeout: TimeInterval,
        overallTimeout: TimeInterval?,
        partialMinInterval: TimeInterval,
        desiredPathIndex: UInt8?,
        onProgress: ((_ bytesReceived: UInt64, _ totalBytes: UInt64) -> Void)?
    ) async throws -> (temporaryFilePath: String, metadata: FileMetadata) {
        try Task.checkCancellation()
        
        let network = try await getOrCreateNetwork()
        try Task.checkCancellation()
        
        let handleBox: RequestHandleBox = RequestHandleBox(nil)
        let temporaryFilePath: String = dependencies[singleton: .fileManager].temporaryFilePath()
        let context: StreamingDownloadContext = try StreamingDownloadContext(
            filePath: temporaryFilePath,
            onProgress: onProgress,
            using: dependencies
        )
        
        let contextPtr: UnsafeMutableRawPointer = Unmanaged.passRetained(context).toOpaque()
        let metadata: FileMetadata = try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    context.setContinuation(continuation)
                    
                    var callbacks = session_download_callbacks(
                        on_data: { metadata, dataPtr, dataLen, ctx in
                            guard
                                let ctx,
                                let dataPtr,
                                dataLen > 0
                            else { return }
                            
                            let context = Unmanaged<StreamingDownloadContext>
                                .fromOpaque(ctx)
                                .takeUnretainedValue()
                            
                            guard let fileHandle: (any FileHandleType) = context.fileHandle else {
                                context.writeError = NetworkError.invalidState
                                return
                            }
                            
                            let dataToWrite = Data(bytes: dataPtr, count: dataLen)
                            
                            do {
                                try fileHandle.write(contentsOf: dataToWrite)
                                
                                /// Update progress
                                context.totalBytesReceived += UInt64(dataLen)
                                context.expectedSize = (metadata?.pointee.size ?? 0)
                                context.onProgress?(
                                    context.totalBytesReceived,
                                    context.expectedSize
                                )
                            }
                            catch {
                                context.writeError = error
                            }
                        },
                        on_complete: { metadata, statusCode, timeout, ctx in
                            guard let ctx: UnsafeMutableRawPointer = ctx else { return }
                            defer { Unmanaged<StreamingDownloadContext>.fromOpaque(ctx).release() }
                            
                            let context: StreamingDownloadContext = Unmanaged<StreamingDownloadContext>
                                .fromOpaque(ctx)
                                .takeUnretainedValue()
                            try? context.fileHandle?.close()
                            
                            if let writeError: Error = context.writeError {
                                context.resumeOnce(throwing: writeError)
                                return
                            }
                            
                            if let metadata: session_file_metadata = metadata?.pointee {
                                context.resumeOnce(returning: FileMetadata(metadata))
                                return
                            }
                            
                            do {
                                try LibSessionNetwork.throwErrorIfNeeded((false, timeout, Int(statusCode), [:], nil))
                                throw NetworkError.invalidResponse
                            }
                            catch { context.resumeOnce(throwing: error) }
                        },
                        ctx: contextPtr
                    )
                    
                    let handle: OpaquePointer? = downloadUrl.withCString { downloadUrlPtr in
                        withUnsafePointer(to: &callbacks) { callbacksPtr in
                            session_network_download(
                                network,
                                downloadUrlPtr,
                                callbacksPtr,
                                Int64(stallTimeout * 1000),
                                Int64(requestTimeout * 1000),
                                overallTimeout.map { Int64($0 * 1000) } ?? 0,
                                Int64(partialMinInterval * 1000),
                                (desiredPathIndex.map { Int8($0) } ?? -1)
                            )
                        }
                    }
                    
                    guard let handle else {
                        context.resumeOnce(throwing: NetworkError.invalidRequest)
                        Unmanaged<StreamingDownloadContext>.fromOpaque(contextPtr).release()
                        return
                    }
                    
                    /// Store for cancellation, `StreamingDownloadContext` will be released via
                    /// `onSuccess`/`onError`
                    handleBox.handle = handle
                }
            },
            onCancel: {
                context.resumeOnce(throwing: CancellationError())
                
                if let handle: OpaquePointer = handleBox.handle {
                    handleBox.handle = nil
                    session_network_download_cancel(handle)
                    session_network_download_free(handle)
                }
            }
        )
        
        if let handle: OpaquePointer = handleBox.handle {
            handleBox.handle = nil
            session_network_download_free(handle)
        }
        
        return (temporaryFilePath, metadata)
    }
    
    public func generateDownloadUrl(fileId: String) async throws -> String {
        guard let cFileId: [CChar] = fileId.cString(using: .utf8) else {
            throw NetworkError.invalidURL
        }
        
        let network = try await getOrCreateNetwork()
        
        var url: [CChar] = [CChar](repeating: 0, count: 1024)
        
        let result = try LibSessionNetwork.withCustomFileServer(dependencies[feature: .customFileServer]) { schemePtr, hostPtr, _, pubkeyPtr in
            session_file_server_generate_download_url(
                cFileId,
                schemePtr,
                hostPtr,
                pubkeyPtr,
                dependencies[feature: .useStreamEncryptionForAttachments],
                &url,
                url.count
            )
        }
        
        guard result else { throw NetworkError.invalidURL }
        
        return String(cString: url)
    }
    
    public func checkClientVersion(ed25519SecretKey: [UInt8]) async throws -> (info: ResponseInfoType, value: Network.FileServer.AppVersionResponse) {
        typealias Continuation = CheckedContinuation<Response, Error>
        
        let network = try await getOrCreateNetwork()
        var cEd25519SecretKey: [UInt8] = Array(ed25519SecretKey)
        
        guard ed25519SecretKey.count == 64 else { throw LibSessionError.invalidCConversion }
        let paramsPtr: UnsafeMutablePointer<session_request_params> = try session_file_server_get_client_version(
            CLIENT_PLATFORM_IOS,
            &cEd25519SecretKey,
            Int64(floor(Network.defaultTimeout * 1000)),
            0
        ) ?? { throw NetworkError.invalidRequest }()
        defer { session_request_params_free(paramsPtr) }
        
        let result: Response = try await withCheckedThrowingContinuation { continuation in
            let box = LibSessionNetwork.ContinuationBox(continuation)
            session_network_send_request(network, paramsPtr, box.cCallback, box.unsafePointer())
        }
        
        try LibSessionNetwork.throwErrorIfNeeded(result)
        let data: Data = try result.data ?? { throw NetworkError.parsingFailed }()
        
        return (
            Network.ResponseInfo(code: result.statusCode),
            try Network.FileServer.AppVersionResponse.decoded(from: data, using: dependencies)
        )
    }
    
    public func resetNetworkStatus() async {
        guard !isSuspended, let network = try? await getOrCreateNetwork() else { return }
        
        let status: NetworkStatus = NetworkStatus(status: session_network_get_status(network))
        
        Log.info(.network, "Network status changed to: \(status)")
        await internalNetworkStatus.send(status)
    }
    
    public func setNetworkStatus(status: NetworkStatus) async {
        guard status == .disconnected || !isSuspended else {
            Log.warn(.network, "Attempted to update network status to '\(status)' for suspended network, closing connections again.")
            
            switch network {
                case .none: return
                case .some(let network): return session_network_close_connections(network)
            }
        }
        
        /// If we have set the `forceOffline` flag then don't allow non-disconnected status updates
        guard status == .disconnected || !dependencies[feature: .forceOffline] else { return }
        
        /// Notify any subscribers
        Log.info(.network, "Network status changed to: \(status)")
        await internalNetworkStatus.send(status)
    }
    
    public func setNetworkInfo(networkTimeOffsetMs: Int64, hardfork: Int, softfork: Int) async {
        var targetHardfork: Int?
        var targetSoftfork: Int?
        
        /// Check if the version info is newer than the current stored values and update them if so
        if hardfork > 1 {
            let oldHardfork: Int = dependencies[defaults: .standard, key: .hardfork]
            let oldSoftfork: Int = dependencies[defaults: .standard, key: .softfork]
            
            if (hardfork > oldHardfork) {
                targetHardfork = hardfork
                targetSoftfork = softfork
                dependencies[defaults: .standard, key: .hardfork] = hardfork
                dependencies[defaults: .standard, key: .softfork] = softfork
            }
            else if softfork > oldSoftfork {
                targetSoftfork = softfork
                dependencies[defaults: .standard, key: .softfork] = softfork
            }
        }
        
        /// Update the cached synchronous state
        syncState.update(
            hardfork: targetHardfork,
            softfork: targetSoftfork,
            networkTimeOffsetMs: networkTimeOffsetMs
        )
    }
    
    public func suspendNetworkAccess() async {
        Log.info(.network, "Network access suspended.")
        isSuspended = true
        syncState.update(isSuspended: true)
        await setNetworkStatus(status: .disconnected)
        await dependencies.notify(key: .networkLifecycle(.suspended))
        
        switch network {
            case .none: break
            case .some(let network): session_network_suspend(network)
        }
    }
    
    public func resumeNetworkAccess(autoReconnect: Bool) async {
        isSuspended = false
        syncState.update(isSuspended: false)
        Log.info(.network, "Network access resumed.")
        await dependencies.notify(key: .networkLifecycle(.resumed))
        
        switch network {
            case .none: break
            case .some(let network): session_network_resume(network, autoReconnect)
        }
    }
    
    public func finishCurrentObservations() async {
        await internalNetworkStatus.finishCurrentStreams()
    }
    
    public func clearCache() async {
        switch network {
            case .none: break
            case .some(let network): session_network_clear_cache(network)
        }
    }
    
    public func shutdown() async {
        initTask?.cancel()
        
        // Cleanup the resources we used
        LibSessionNetwork.cleanupResources(
            network: network,
            contextPtr: contextPtr
        )
        self.network = nil
        self.contextPtr = nil
    }
    
    // MARK: - Internal Functions
    
    private func getOrCreateNetwork() async throws -> UnsafeMutablePointer<network_object> {
        guard !isSuspended else {
            Log.warn(.network, "Attempted to access suspended network.")
            throw NetworkError.suspended
        }
        
        /// If the `forceOffline` dev setting is on then fail the request after a `1s` delay
        guard !dependencies[feature: .forceOffline] else {
            try await Task.sleep(for: .seconds(1))
            throw NetworkError.serviceUnavailable
        }
        
        /// If we already have a network instance then return it
        if let existing: UnsafeMutablePointer<network_object> = network {
            return existing
        }
        
        /// Configure the network based on the client settings
        let targetCachePath: String = (customCachePath ?? LibSessionNetwork.snodeCachePath)
        
        guard let cCachePath: [CChar] = targetCachePath.cString(using: .utf8) else {
            Log.error(.network, "Unable to create network object: \(LibSessionError.invalidCConversion)")
            throw NetworkError.invalidState
        }
        
        let staticNodeListPath: String? = Bundle.main
            .url(forResource: "service-nodes-cache", withExtension: "json")?
            .path
        
        if staticNodeListPath == nil {
            Log.warn(.network, "Unable to find bundled static node list foor bootstrap fallback")
        }
        
        let serviceNetwork: ServiceNetwork = dependencies[feature: .serviceNetwork]
        var error: [CChar] = [CChar](repeating: 0, count: 256)
        var network: UnsafeMutablePointer<network_object>?
        var cDevnetNodes: [network_service_node] = []
        var config: session_network_config = session_network_config_default()
        
        switch (serviceNetwork, dependencies[feature: .devnetConfig], dependencies[feature: .devnetConfig].isValid) {
            case (.mainnet, _, _): config.netid = SESSION_NETWORK_MAINNET
            case (.testnet, _, _), (_, _, false):
                config.netid = SESSION_NETWORK_TESTNET
                config.enforce_subnet_diversity = false /// On testnet we can't do this as nodes share IPs
                Log.info(.network, "Setting up connection to testnet")
                
            case (.devnet, let devnetConfig, true):
                config.netid = SESSION_NETWORK_DEVNET
                config.enforce_subnet_diversity = false /// Devnet nodes likely share IPs as well
                cDevnetNodes = [LibSession.Snode(devnetConfig).cSnode]
                Log.info(.network, "Setting up connection to devnet (ip: \(devnetConfig.ip), quic port: \(devnetConfig.omqPort))")
        }
        
        switch dependencies[feature: .router] {
            case .onionRequests: config.router = SESSION_NETWORK_ROUTER_ONION_REQUESTS
            case .sessionRouter: config.router = SESSION_NETWORK_ROUTER_SESSION_ROUTER
            case .direct: config.router = SESSION_NETWORK_ROUTER_DIRECT
        }
        
        /// If it's not the main app then we want to run in "Single Path Mode" (no use creating extra paths in the extensions)
        if !dependencies[singleton: .appContext].isMainApp {
            config.onionreq_single_path_mode = true
        }
        else {
            /// Otherwise apply any path count settings
            if
                dependencies[feature: .onionRequestMinStandardPaths] > 0 &&
                dependencies[feature: .onionRequestMinStandardPaths] <= UInt8.max
            {
                config.onionreq_min_path_count_standard = UInt8(dependencies[feature: .onionRequestMinStandardPaths])
            }
            
            if
                dependencies[feature: .onionRequestMinFilePaths] > 0 &&
                dependencies[feature: .onionRequestMinFilePaths] <= UInt8.max
            {
                config.onionreq_min_path_count_file = UInt8(dependencies[feature: .onionRequestMinFilePaths])
            }
        }
        
        try LibSessionNetwork.withCustomFileServer(dependencies[feature: .customFileServer]) { schemePtr, hostPtr, port, pubkeyPtr in
            try cCachePath.withUnsafeBufferPointer { cachePtr in
                try LibSessionNetwork.withOptionalCString(staticNodeListPath) { staticNodesListPtr in
                    try cDevnetNodes.withUnsafeBufferPointer { devnetNodesPtr in
                        config.cache_dir = cachePtr.baseAddress
                        
                        /// Only set the `fallback_snode_pool_path` if we are using `mainnet` (as the data comes from
                        /// `mainnet` so will be incorrect in any other environment)
                        if let staticNodesListPtr, serviceNetwork == .mainnet {
                            config.fallback_snode_pool_path = staticNodesListPtr
                        }
                        
                        /// Only set the devnet pointers if we are in devnet mode
                        if config.netid == SESSION_NETWORK_DEVNET {
                            config.devnet_seed_nodes = devnetNodesPtr.baseAddress
                            config.devnet_seed_nodes_size = devnetNodesPtr.count
                        }
                        
                        if let schemePtr {
                            config.custom_file_server_scheme = schemePtr
                        }
                        
                        if let hostPtr {
                            config.custom_file_server_host = hostPtr
                        }
                        
                        if let port {
                            config.custom_file_server_port = port
                        }
                        
                        if let pubkeyPtr {
                            config.custom_file_server_pubkey_hex = pubkeyPtr
                        }
                        
                        guard session_network_init(&network, &config, &error) else {
                            let errorString: String = String(cString: error)
                            
#if targetEnvironment(simulator)
                            if errorString == "Address already in use" {
                                Log.critical(.network, "Failed to create network object, if you are using Session Router then it's possible another simulator instance is running and using the same port. Please close any other simulator instances and try again.")
                            }
#endif
                            
                            Log.error(.network, "Unable to create network object: \(errorString)")
                            throw NetworkError.invalidState
                        }
                    }
                }
            }
        }
        
        /// If the task is cancelled then we need to free `network`
        if Task.isCancelled {
             session_network_free(network)
             throw CancellationError()
        }
        
        /// Store the newly created network
        self.network = network
        
        session_network_set_status_changed_callback(network, { cStatus, ctx in
            guard let ctx: UnsafeMutableRawPointer = ctx else { return }
            
            let status: NetworkStatus = NetworkStatus(status: cStatus)
            let context: Context = Unmanaged<Context>.fromOpaque(ctx).takeUnretainedValue()
            
            guard let network: LibSessionNetwork = context.network else { return }
            
            /// Kick off a task so we don't hold up the libSession thread that triggered the update
            Task { await network.setNetworkStatus(status: status) }
        }, contextPtr)
        
        session_network_set_network_info_changed_callback(network, { timeOffsetMs, hardfork, softfork, ctx in
            guard let ctx: UnsafeMutableRawPointer = ctx else { return }
            
            let context: Context = Unmanaged<Context>.fromOpaque(ctx).takeUnretainedValue()
            
            guard let network: LibSessionNetwork = context.network else { return }
            
            /// Kick off a task so we don't hold up the libSession thread that triggered the update
            Task {
                await network.setNetworkInfo(
                    networkTimeOffsetMs: Int64(timeOffsetMs),
                    hardfork: Int(hardfork),
                    softfork: Int(softfork)
                )
            }
        }, contextPtr)
        
        return try network ?? { throw NetworkError.invalidState }()
    }
    
    private func sendRequest<T: Encodable>(
        endpoint: (any EndpointType),
        destination: Network.Destination,
        body: T?,
        category: Network.RequestCategory,
        requestTimeout: TimeInterval,
        overallTimeout: TimeInterval?
    ) async throws -> (info: ResponseInfoType, value: Data?) {
        typealias Continuation = CheckedContinuation<Response, Error>
        try Task.checkCancellation()
        
        let network = try await getOrCreateNetwork()
        try Task.checkCancellation()
        
        let result: Response = try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { continuation in
                    let box = LibSessionNetwork.ContinuationBox(continuation)
                    
                    /// Define the callback to avoid dupolication
                    let context = box.unsafePointer()
                    let request: Request<T> = Request(
                        endpoint: endpoint,
                        body: body,
                        category: category,
                        requestTimeout: requestTimeout,
                        overallTimeout: overallTimeout
                    )
                    
                    do {
                        switch destination {
                            case .snode(let snode, _):
                                try LibSessionNetwork.withSnodeRequestParams(request, snode) { paramsPtr in
                                    session_network_send_request(network, paramsPtr, box.cCallback, context)
                                }
                                
                            case .server(let info), .serverUpload(let info, _):
                                let uploadFileName: String? = {
                                    switch destination {
                                        case .serverUpload(_, let fileName): return fileName
                                        default: return nil
                                    }
                                }()
                                
                                try LibSessionNetwork.withServerRequestParams(request, info, uploadFileName) { paramsPtr in
                                    session_network_send_request(network, paramsPtr, box.cCallback, context)
                                }
                                
                            /// Some destinations are for convenience and redirect to "proper" destination types so if one of them gets here
                            /// then it is invalid
                            default: throw NetworkError.invalidRequest
                        }
                    }
                    catch { box.resumeOnce(throwing: error) }
                }
            },
            onCancel: {
                Log.info(.network, "Request cancelled by Task, libSession will still complete/timeout")
            }
        )
        
        try Task.checkCancellation()
        
        try LibSessionNetwork.throwErrorIfNeeded(result)
        return (Network.ResponseInfo(code: result.statusCode, headers: result.headers), result.data)
    }
    
    private static func throwErrorIfNeeded(_ response: Response) throws {
        guard !response.success || response.statusCode < 200 || response.statusCode > 299 else { return }
        guard !response.timeout else {
            switch response.data.map({ String(data: $0, encoding: .ascii) }) {
                case .none: throw NetworkError.timeout(error: "\(NetworkError.unknown)", rawData: response.data)
                case .some(let responseString):
                    throw NetworkError.timeout(error: responseString, rawData: response.data)
            }
        }
        
        /// Handle status codes with specific meanings
        switch (response.statusCode, response.data.map { String(data: $0, encoding: .ascii) }) {
            case (400, .none):
                throw NetworkError.badRequest(error: "\(NetworkError.unknown)", rawData: response.data)
                
            case (400, .some(let responseString)):
                throw NetworkError.badRequest(error: responseString, rawData: response.data)
                
            case (401, _):
                Log.warn(.network, "Unauthorised (Failed to verify the signature).")
                throw NetworkError.unauthorised
            
            case (403, _): throw NetworkError.forbidden
            case (404, _): throw NetworkError.notFound
                
            /// A snode will return a `406` but onion requests v4 seems to return `425` so handle both
            case (406, _), (425, _):
                Log.warn(.network, "The user's clock is out of sync with the service node network.")
                throw StorageServerError.clockOutOfSync
            
            case (408, .none):
                throw NetworkError.timeout(error: "\(NetworkError.unknown)", rawData: response.data)
                
            case (408, .some(let responseString)):
                throw NetworkError.timeout(error: responseString, rawData: response.data)
                
            case (421, _): throw StorageServerError.unassociatedPubkey
            case (429, _): throw StorageServerError.rateLimited
            case (500, _): throw NetworkError.internalServerError
            case (503, _): throw NetworkError.serviceUnavailable
            case (502, .none): throw NetworkError.badGateway
            case (502, .some(let responseString)):
                guard responseString.count >= 64 && Hex.isValid(String(responseString.suffix(64))) else {
                    throw NetworkError.badGateway
                }
                
                throw StorageServerError.nodeNotFound(String(responseString.suffix(64)))
                
            case (504, _): throw NetworkError.gatewayTimeout
            case (LibSessionNetworkError.suspended.rawValue, _): throw NetworkError.suspended
            case (LibSessionNetworkError.invalidDownloadUrl.rawValue, _): throw NetworkError.invalidURL
            case (LibSessionNetworkError.requestCancelled.rawValue, _): throw CancellationError()
            case (_, .none): throw NetworkError.unknown
            case (_, .some(let responseString)):
                throw NetworkError.requestFailed(error: responseString, rawData: response.data)
        }
    }
}

// MARK: - LibSessionNetwork.Context

private extension LibSessionNetwork {
    /// Helper class to pass to C-API
    private class Context {
        weak var network: LibSessionNetwork?
        
        init(network: LibSessionNetwork) {
            self.network = network
        }
    }
}

private extension LibSessionNetwork {
    class ContinuationBox<T> {
        private let lock: NSLock = NSLock()
        private var continuation: CheckedContinuation<T, Error>?
        private var hasResumed: Bool = false
        
        init(_ continuation: CheckedContinuation<T, Error>) {
            self.continuation = continuation
        }
        
        // MARK: - Functions
        
        private func shouldResume() -> Bool {
            lock.withLock { () -> Bool in
                guard !hasResumed else {
                    Log.warn(.network, "Attempted to resume continuation multiple times - ignoring")
                    return false
                }
                hasResumed = true
                return true
            }
        }
        
        public func unsafePointer() -> UnsafeMutableRawPointer { Unmanaged.passRetained(self).toOpaque() }
        public static func from(unsafePointer: UnsafeMutableRawPointer?) -> ContinuationBox<T>? {
            guard let ptr: UnsafeMutableRawPointer = unsafePointer else { return nil }
            
            return Unmanaged<ContinuationBox<T>>.fromOpaque(ptr).takeRetainedValue()
        }
        
        public func resumeOnce(returning value: T) {
            guard shouldResume(), let cont: CheckedContinuation<T, Error> = continuation else { return }
            
            /// Clear continuation reference before resuming to allow deallocation
            lock.withLock { continuation = nil }
            
            /// Kick off a task so we don't hold up the libSession thread that triggered the update
            Task {
                cont.resume(returning: value)
            }
        }
        
        public func resumeOnce(throwing error: Error) {
            guard shouldResume(), let cont: CheckedContinuation<T, Error> = continuation else { return }
            
            /// Clear continuation reference before resuming to allow deallocation
            lock.withLock { continuation = nil }
            
            /// Kick off a task so we don't hold up the libSession thread that triggered the update
            Task {
                cont.resume(throwing: error)
            }
        }
    }
    
    final class RequestHandleBox: @unchecked Sendable {
        var handle: OpaquePointer?
        
        init(_ handle: OpaquePointer?) {
            self.handle = handle
        }
    }
    
    class StreamingUploadContext {
        private let lock: NSLock = NSLock()
        private var continuation: CheckedContinuation<FileMetadata, Error>?
        private var hasResumed: Bool = false
        
        var fileHandle: FileHandleType?
        let expectedFileSize: Int64
        var bytesRead: Int64 = 0
        
        init(fileURL: URL, using dependencies: Dependencies) throws {
            self.expectedFileSize = ((try? dependencies[singleton: .fileManager]
                .attributesOfItem(atPath: fileURL.path)[.size] as? Int64) ?? -1)
            self.fileHandle = try dependencies[singleton: .fileHandleFactory].create(
                forReadingFrom: fileURL
            )
        }
        
        func setContinuation(_ continuation: CheckedContinuation<FileMetadata, Error>) {
            self.continuation = continuation
        }
        
        private func shouldResume() -> Bool {
            lock.withLock {
                guard !hasResumed else { return false }
                hasResumed = true
                return true
            }
        }
        
        func resumeOnce(returning value: FileMetadata) {
            guard shouldResume() else { return }
            
            try? fileHandle?.close()
            fileHandle = nil
            
            guard let continuation else {
                Log.warn(.network, "Attempted to resume upload context but continuation was nil")
                return
            }
            
            continuation.resume(returning: value)
        }
        
        func resumeOnce(throwing error: Error) {
            guard shouldResume() else { return }
            
            try? fileHandle?.close()
            fileHandle = nil
            
            guard let continuation else {
                Log.warn(.network, "Attempted to resume upload context but continuation was nil")
                return
            }
            
            continuation.resume(throwing: error)
        }
    }
    
    class StreamingDownloadContext {
        private let dependencies: Dependencies
        private let lock: NSLock = NSLock()
        private var continuation: CheckedContinuation<FileMetadata, Error>?
        private var hasResumed: Bool = false
        
        var fileHandle: (any FileHandleType)?
        var onProgress: ((UInt64, UInt64) -> Void)?
        var filePath: String
        var totalBytesReceived: UInt64 = 0
        var expectedSize: UInt64 = 0
        var writeError: Error?
        
        init(
            filePath: String,
            onProgress: ((UInt64, UInt64) -> Void)?,
            using dependencies: Dependencies
        ) throws {
            self.dependencies = dependencies
            self.filePath = filePath
            self.onProgress = onProgress
            
            _ = dependencies[singleton: .fileManager].createFile(
                atPath: filePath,
                contents: nil
            )
            
            self.fileHandle = dependencies[singleton: .fileHandleFactory].create(
                forWritingAtPath: filePath
            )
        }
        
        func setContinuation(_ continuation: CheckedContinuation<FileMetadata, Error>) {
            self.continuation = continuation
        }
        
        private func shouldResume() -> Bool {
            lock.withLock {
                guard !hasResumed else { return false }
                hasResumed = true
                return true
            }
        }
        
        func resumeOnce(returning value: FileMetadata) {
            guard shouldResume() else { return }
            
            try? fileHandle?.close()
            fileHandle = nil
            
            guard let continuation else {
                Log.warn(.network, "Attempted to resume download context but continuation was nil")
                return
            }
            
            continuation.resume(returning: value)
        }
        
        func resumeOnce(throwing error: Error) {
            guard shouldResume() else { return }
            
            try? fileHandle?.close()
            fileHandle = nil

            /// Clean up the temporary file if an error occurred
            try? dependencies[singleton: .fileManager].removeItem(atPath: filePath)
            
            guard let continuation else {
                Log.warn(.network, "Attempted to resume download context but continuation was nil")
                return
            }
            
            continuation.resume(throwing: error)
        }
    }
}

extension LibSessionNetwork.ContinuationBox where T == LibSessionNetwork.Response {
    var cCallback: session_network_response_t {
        return { success, timeout, statusCode, cHeaders, cHeadersLen, dataPtr, dataLen, ctx in
            guard let box = LibSessionNetwork.ContinuationBox<T>.from(unsafePointer: ctx) else {
                return
            }
            
            let headers: [String: String] = LibSessionNetwork.headers(cHeaders, cHeadersLen)
            let data: Data? = dataPtr.map { Data(bytes: $0, count: dataLen) }
            box.resumeOnce(returning: (success, timeout, Int(statusCode), headers, data))
        }
    }
}

// MARK: - NetworkStatus Convenience

private extension NetworkStatus {
    init(status: CONNECTION_STATUS) {
        switch status {
            case CONNECTION_STATUS_CONNECTING: self = .connecting
            case CONNECTION_STATUS_CONNECTED: self = .connected
            case CONNECTION_STATUS_DISCONNECTED: self = .disconnected
            default: self = .unknown
        }
    }
}

// MARK: - Snode

extension LibSession {
    public struct Path {
        public let nodes: [LibSession.Snode]
        public let category: Network.PathCategory?
        public let destinationPubkey: String?
        public let destinationSnodeAddress: String?
        
        public var pathDescription: String {
            "[\(nodes.map { "\($0.httpsAddress)" }.joined(separator: ", ")) (\(nodes.map { $0.ed25519PubkeyHex.prefix(7) }.joined(separator: " → ")))]"
        }
    }
}

extension LibSession {
    public struct Snode: Codable, Hashable, CustomStringConvertible {
        public let ed25519PubkeyHex: String
        public let ip: String
        public let httpsPort: UInt16
        public let omqPort: UInt16
        public let version: String
        public let swarmId: UInt64
        
        public var httpsAddress: String { "\(ip):\(httpsPort)" }
        public var omqAddress: String { "\(ip):\(omqPort)" }
        public var description: String { omqAddress }
        
        public var cSnode: network_service_node {
            var result: network_service_node = network_service_node()
            result.set(\.ed25519_pubkey_hex, to: ed25519PubkeyHex)
            result.ipString = ip
            result.set(\.https_port, to: httpsPort)
            result.set(\.omq_port, to: omqPort)
            result.versionString = version
            result.set(\.swarm_id, to: swarmId)
            
            return result
        }
        
        init(_ cSnode: network_service_node) {
            ed25519PubkeyHex = cSnode.get(\.ed25519_pubkey_hex)
            ip = cSnode.ipString
            httpsPort = cSnode.get(\.https_port)
            omqPort = cSnode.get(\.omq_port)
            version = cSnode.versionString
            swarmId = cSnode.get(\.swarm_id)
        }
        
        internal init(_ config: ServiceNetwork.DevnetConfiguration) {
            self.ed25519PubkeyHex = config.pubkey
            self.ip = config.ip
            self.httpsPort = config.httpPort
            self.omqPort = config.omqPort
            self.version = ""
            self.swarmId = 0
        }
        
        internal init(
            ed25519PubkeyHex: String,
            ip: String,
            httpsPort: UInt16,
            quicPort: UInt16,
            version: String,
            swarmId: UInt64
        ) {
            self.ed25519PubkeyHex = ed25519PubkeyHex
            self.ip = ip
            self.httpsPort = httpsPort
            self.omqPort = quicPort
            self.version = version
            self.swarmId = swarmId
        }
        
        public func hash(into hasher: inout Hasher) {
            ed25519PubkeyHex.hash(into: &hasher)
            ip.hash(into: &hasher)
            httpsPort.hash(into: &hasher)
            omqPort.hash(into: &hasher)
            version.hash(into: &hasher)
            swarmId.hash(into: &hasher)
        }
        
        public static func == (lhs: Snode, rhs: Snode) -> Bool {
            return (
                lhs.ed25519PubkeyHex == rhs.ed25519PubkeyHex &&
                lhs.ip == rhs.ip &&
                lhs.httpsPort == rhs.httpsPort &&
                lhs.omqPort == rhs.omqPort &&
                lhs.version == rhs.version &&
                lhs.swarmId == rhs.swarmId
            )
        }
    }
}

// MARK: - Convenience C Access

extension network_service_node: @retroactive CAccessible, @retroactive CMutable {
    var ipString: String {
        get { "\(ip.0).\(ip.1).\(ip.2).\(ip.3)" }
        set {
            let ipParts: [UInt8] = newValue
                .components(separatedBy: ".")
                .compactMap { UInt8($0) }
            
            guard ipParts.count == 4 else { return }
            
            self.ip = (ipParts[0], ipParts[1], ipParts[2], ipParts[3])
        }
    }
    
    var versionString: String {
        get { "\(version.0).\(version.1).\(version.2)" }
        set {
            let versionParts: [UInt16] = newValue
                .components(separatedBy: ".")
                .compactMap { UInt16($0) }
            
            guard versionParts.count == 3 else { return }
            
            self.version = (versionParts[0], versionParts[1], versionParts[2])
        }
    }
}

// MARK: - Convenience

private extension LibSessionNetwork {
    struct Request<T: Encodable> {
        let endpoint: (any EndpointType)
        let body: T?
        let category: Network.RequestCategory
        let requestTimeout: TimeInterval
        let overallTimeout: TimeInterval?
    }
    
    static func withCustomFileServer<Result>(
        _ customFileServer: Network.FileServer.Custom,
        _ callback: (UnsafePointer<CChar>?, UnsafePointer<CChar>?, UInt16?, UnsafePointer<CChar>?) throws -> Result
    ) throws -> Result {
        guard
            customFileServer.isValid,
            let url: URL = URL(string: customFileServer.url)
        else { return try callback(nil, nil, nil, nil) }
        
        let scheme: String? = url.scheme
        let host: String? = url.host
        let port: UInt16? = url.port.map { UInt16($0) }
        let pubkey: String? = (customFileServer.pubkey.isEmpty ? nil : customFileServer.pubkey)
        
        return try withOptionalCString(scheme) { schemePtr in
            try withOptionalCString(host) { hostPtr in
                try withOptionalCString(pubkey) { pubkeyPtr in
                    try callback(schemePtr, hostPtr, port, pubkeyPtr)
                }
            }
        }
    }
    
    static func withSnodeRequestParams<T: Encodable, Result>(
        _ request: Request<T>,
        _ node: LibSession.Snode,
        _ callback: (UnsafePointer<session_request_params>) -> Result
    ) throws -> Result {
        var cSnode = node.cSnode
        
        return try withBodyPointer(request.body) { cBodyPtr, bodySize in
            withUnsafePointer(to: &cSnode) { cSnodePtr in
                request.endpoint.path.withCString { cEndpoint in
                    let params: session_request_params = session_request_params(
                        snode_dest: cSnodePtr,
                        server_dest: nil,
                        remote_addr_dest: nil,
                        endpoint: cEndpoint,
                        body: cBodyPtr,
                        body_size: bodySize,
                        category: request.category.libSessionValue,
                        request_timeout_ms: safeTimeoutMs(request.requestTimeout),
                        overall_timeout_ms: safeTimeoutMs(request.overallTimeout ?? 0),
                        upload_file_name: nil,
                        request_id: nil
                    )
                    
                    return withUnsafePointer(to: params) { paramsPtr in
                        callback(paramsPtr)
                    }
                }
            }
        }
    }
    
    static func withServerRequestParams<T: Encodable, Result>(
        _ request: Request<T>,
        _ info: Network.Destination.ServerInfo,
        _ uploadFileName: String?,
        _ callback: (UnsafePointer<session_request_params>) -> Result
    ) throws -> Result {
        return try withBodyPointer(request.body) { cBodyPtr, bodySize in
            let pathWithParamsAndFrags: String = Network.Destination.generatePathWithParamsAndFragments(
                endpoint: request.endpoint,
                queryParameters: info.queryParameters,
                fragmentParameters: info.fragmentParameters
            )
            
            return try pathWithParamsAndFrags.withCString { cEndpoint in
                try withFileNamePtr(uploadFileName) { cUploadFileNamePtr in
                    try info.withServerInfoPointer { cServerDestinationPtr in
                        let params: session_request_params = session_request_params(
                            snode_dest: nil,
                            server_dest: cServerDestinationPtr,
                            remote_addr_dest: nil,
                            endpoint: cEndpoint,
                            body: cBodyPtr,
                            body_size: bodySize,
                            category: request.category.libSessionValue,
                            request_timeout_ms: safeTimeoutMs(request.requestTimeout),
                            overall_timeout_ms: safeTimeoutMs(request.overallTimeout ?? 0),
                            upload_file_name: cUploadFileNamePtr,
                            request_id: nil
                        )
                        
                        return withUnsafePointer(to: params) { paramsPtr in
                            callback(paramsPtr)
                        }
                    }
                }
            }
        }
    }
    
    private static func withFileNamePtr<Result>(
        _ uploadFilename: String?,
        _ closure: (UnsafePointer<Int8>?) throws -> Result
    ) throws -> Result {
        switch uploadFilename {
            case .none: return try closure(nil)
            case .some(let filename): return try filename.withCString { try closure($0) }
        }
    }

    private static func withBodyPointer<T: Encodable, Result>(
        _ body: T?,
        _ closure: (UnsafePointer<UInt8>?, Int) throws -> Result
    ) throws -> Result {
        let maybeBodyData: Data?
        
        switch body {
            case .none: maybeBodyData = nil
            case let data as Data: maybeBodyData = data
            case let bytes as [UInt8]: maybeBodyData = Data(bytes)
            default:
                guard let encodedBody: Data = try? JSONEncoder().encode(body) else {
                    throw StorageServerError.invalidPayload
                }
                
                maybeBodyData = encodedBody
        }
        
        guard let bodyData: Data = maybeBodyData, !bodyData.isEmpty else {
            return try closure(nil, 0)
        }
        
        return try bodyData.withUnsafeBytes { (rawPtr: UnsafeRawBufferPointer) in
            let ptr: UnsafePointer<UInt8>? = rawPtr.baseAddress?.assumingMemoryBound(to: UInt8.self)
            return try closure(ptr, bodyData.count)
        }
    }
    
    private static func withOptionalCString<Result>(
        _ string: String?,
        _ body: (UnsafePointer<CChar>?) throws -> Result
    ) throws -> Result {
        guard let string else { return try body(nil) }
        
        return try string.withCString(body)
    }
    
    private static func safeTimeoutMs(_ timeout: TimeInterval) -> UInt64 {
        guard timeout.isFinite, timeout >= 0 else {
            Log.warn(.network, "Invalid timeout value: \(timeout), using 0")
            return 0
        }
        
        let ms: Double = (timeout * 1000)
        
        guard ms >= 0, ms <= Double(UInt64.max) else {
            Log.warn(.network, "Timeout value out of range: \(timeout), clamping")
            return ms < 0 ? 0 : UInt64.max
        }
        
        return UInt64(floor(ms))
    }
}

private extension Network.Destination.ServerInfo {
    func withServerInfoPointer<Result>(_ body: (UnsafePointer<network_server_destination>) -> Result) throws -> Result {
        let x25519PublicKey: String = String(x25519PublicKey.suffix(64)) // Quick way to drop '05' prefix if present
        
        guard let host: String = self.host else { throw NetworkError.invalidURL }
        guard x25519PublicKey.count == 64 || x25519PublicKey.count == 66 else {
            throw LibSessionError.invalidCConversion
        }
        
        let targetScheme: String = (self.scheme ?? "https")
        let port: UInt16 = UInt16(self.port ?? (targetScheme == "https" ? 443 : 80))
        let headersArray: [String] = headers.flatMap { [$0.key, $0.value] }
        
        // Use scoped closure to avoid manual memory management (crazy nesting but it ends up safer)
        return try method.rawValue.withCString { cMethodPtr in
            try targetScheme.withCString { cTargetSchemePtr in
                try host.withCString { cHostPtr in
                    try x25519PublicKey.withCString { cX25519PubkeyPtr in
                        try headersArray.withUnsafeCStrArray { headersArrayPtr in
                            let cServerDest = network_server_destination(
                                method: cMethodPtr,
                                protocol: cTargetSchemePtr,
                                host: cHostPtr,
                                port: port,
                                x25519_pubkey_hex: cX25519PubkeyPtr,
                                headers_kv_pairs: headersArrayPtr.baseAddress,
                                headers_kv_pairs_len: headersArray.count
                            )
                            
                            return withUnsafePointer(to: cServerDest) { ptr in
                                body(ptr)
                            }
                        }
                    }
                }
            }
        }
    }
}

private extension LibSessionNetwork {
    static func headers(_ cHeaders: UnsafePointer<UnsafePointer<CChar>?>?, _ count: Int) -> [String: String] {
        let headersArray: [String] = ([String](cStringArray: cHeaders, count: count) ?? [])
        
        return stride(from: 0, to: headersArray.count, by: 2)
            .reduce(into: [:]) { result, index in
                if (index + index) < headersArray.count {
                    result[headersArray[index]] = headersArray[index + 1]
                }
            }
    }
}

public extension LibSession {
    actor NoopNetwork: NetworkType {
        public let isSuspended: Bool = false
        public let hardfork: Int = 0
        public let softfork: Int = 0
        public var hasRetrievedNetworkTimeOffset: Bool = false
        public let networkTimeOffsetMs: Int64 = 0
        
        nonisolated public let networkStatus: AsyncStream<NetworkStatus> = .makeStream().stream
        nonisolated public let syncState: NetworkSyncState
        
        public init(using dependencies: Dependencies) {
            syncState = NetworkSyncState(
                hardfork: 0,
                softfork: 0,
                using: dependencies
            )
        }
        
        public func getActivePaths() async throws -> [LibSession.Path] { return [] }
        public func getSwarm(for swarmPublicKey: String, ignoreStrikeCount: Bool) async throws -> Set<LibSession.Snode> { return [] }
        public func getRandomNodes(count: Int) async throws -> Set<LibSession.Snode> { return [] }
        
        public func send<E: EndpointType>(
            endpoint: E,
            destination: Network.Destination,
            body: Data?,
            category: Network.RequestCategory,
            requestTimeout: TimeInterval,
            overallTimeout: TimeInterval?
        ) async throws -> (info: ResponseInfoType, value: Data?) {
            throw NetworkError.invalidResponse
        }
        
        public func upload(
            fileURL: URL,
            fileName: String?,
            stallTimeout: TimeInterval,
            requestTimeout: TimeInterval,
            overallTimeout: TimeInterval?,
            desiredPathIndex: UInt8?
        ) async throws -> FileMetadata {
            throw NetworkError.invalidResponse
        }
        public func download(
            downloadUrl: String,
            stallTimeout: TimeInterval,
            requestTimeout: TimeInterval,
            overallTimeout: TimeInterval?,
            partialMinInterval: TimeInterval,
            desiredPathIndex: UInt8?,
            onProgress: ((_ bytesReceived: UInt64, _ totalBytes: UInt64) -> Void)?
        ) async throws -> (temporaryFilePath: String, metadata: FileMetadata) {
            throw NetworkError.invalidResponse
        }
        
        public func generateDownloadUrl(fileId: String) async throws -> String {
            throw NetworkError.invalidURL
        }
        
        public func checkClientVersion(ed25519SecretKey: [UInt8]) async throws -> (info: ResponseInfoType, value: Network.FileServer.AppVersionResponse) {
            throw NetworkError.invalidRequest
        }
        
        public func resetNetworkStatus() async {}
        public func setNetworkStatus(status: NetworkStatus) async {}
        public func setNetworkInfo(networkTimeOffsetMs: Int64, hardfork: Int, softfork: Int) async {}
        public func suspendNetworkAccess() async {}
        public func resumeNetworkAccess(autoReconnect: Bool) async {}
        public func finishCurrentObservations() async {}
        public func clearCache() async {}
        public func shutdown() async {}
    }
}

extension session_network_config: @retroactive CAccessible, @retroactive CMutable {}
extension session_onion_path_metadata: @retroactive CAccessible {}
extension session_router_tunnel_metadata: @retroactive CAccessible {}
