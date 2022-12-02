// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

/*internal*/public enum SessionUtil {
    public typealias ConfResult = (needsPush: Bool, needsDump: Bool)
    public typealias IncomingConfResult = (needsPush: Bool, needsDump: Bool, latestSentTimestamp: TimeInterval)
    
    enum Target {
        case global(variant: ConfigDump.Variant)
        case custom(conf: Atomic<UnsafeMutablePointer<config_object>?>)
        
        var conf: Atomic<UnsafeMutablePointer<config_object>?> {
            switch self {
                case .global(let variant): return SessionUtil.config(for: variant)
                case .custom(let conf): return conf
            }
        }
    }
    
    // MARK: - Configs
    
    private static var userProfileConfig: Atomic<UnsafeMutablePointer<config_object>?> = Atomic(nil)
    
    // MARK: - Variables
    
    public static var needsSync: Bool {
        return ConfigDump.Variant.allCases.contains { variant in
            switch variant {
                case .userProfile:
                    return (userProfileConfig.wrappedValue.map { config_needs_push($0) } ?? false)
            }
        }
    }
    
    // MARK: - Convenience
    private static func config(for variant: ConfigDump.Variant) -> Atomic<UnsafeMutablePointer<config_object>?> {
        switch variant {
            case .userProfile: return SessionUtil.userProfileConfig
        }
    }
    
    // MARK: - Loading
    
    /*internal*/public static func loadState() {
        SessionUtil.userProfileConfig.mutate { $0 = loadState(for: .userProfile) }
    }
    
    private static func loadState(for variant: ConfigDump.Variant) -> UnsafeMutablePointer<config_object>? {
        // Load any
        let storedDump: Data? = Storage.shared
            .read { db in try ConfigDump.fetchOne(db, id: variant) }?
            .data
        
        return try? loadState(for: variant, cachedData: storedDump)
    }
    
    internal static func loadState(
        for variant: ConfigDump.Variant,
        cachedData: Data? = nil
    ) throws -> UnsafeMutablePointer<config_object>? {
        // Setup initial variables (including getting the memory address for any cached data)
        var conf: UnsafeMutablePointer<config_object>? = nil
        let error: UnsafeMutablePointer<CChar>? = nil
        let cachedDump: (data: UnsafePointer<CChar>, length: Int)? = cachedData?.withUnsafeBytes { unsafeBytes in
            return unsafeBytes.baseAddress.map {
                (
                    $0.assumingMemoryBound(to: CChar.self),
                    unsafeBytes.count
                )
            }
        }
        
        // No need to deallocate the `cachedDump.data` as it'll automatically be cleaned up by
        // the `cachedData` lifecycle, but need to deallocate the `error` if it gets set
        defer {
            error?.deallocate()
        }
        
        // Try to create the object
        let result: Int32 = {
            switch variant {
                case .userProfile:
                    return user_profile_init(&conf, cachedDump?.data, (cachedDump?.length ?? 0), error)
            }
        }()
        
        guard result == 0 else {
            let errorString: String = (error.map { String(cString: $0) } ?? "unknown error")
            SNLog("[SessionUtil Error] Unable to create \(variant.rawValue) config object: \(errorString)")
            throw SessionUtilError.unableToCreateConfigObject
        }
        
        return conf
    }
    
    internal static func saveState(
        _ db: Database,
        conf: UnsafeMutablePointer<config_object>?,
        for variant: ConfigDump.Variant
    ) throws {
        guard conf != nil else { throw SessionUtilError.nilConfigObject }
        
        // If it doesn't need a dump then do nothing
        guard config_needs_dump(conf) else { return }
        
        var dumpResult: UnsafeMutablePointer<CChar>? = nil
        var dumpResultLen: Int = 0
        config_dump(conf, &dumpResult, &dumpResultLen)
        
        guard let dumpResult: UnsafeMutablePointer<CChar> = dumpResult else { return }
        
        let dumpData: Data = Data(bytes: dumpResult, count: dumpResultLen)
        dumpResult.deallocate()
        
        try ConfigDump(
            variant: variant,
            data: dumpData
        )
        .save(db)
    }
    
    // MARK: - Pushes
    
    public static func getChanges(
        for variants: [ConfigDump.Variant] = ConfigDump.Variant.allCases
    ) -> [SharedConfigMessage] {
        return variants
            .compactMap { variant -> SharedConfigMessage? in
                let conf = SessionUtil.config(for: variant)
                
                // Check if the config needs to be pushed
                guard config_needs_push(conf.wrappedValue) else { return nil }
                
                var toPush: UnsafeMutablePointer<CChar>? = nil
                var toPushLen: Int = 0
                let seqNo: Int64 = conf.mutate { config_push($0, &toPush, &toPushLen) }
                
                guard let toPush: UnsafeMutablePointer<CChar> = toPush else { return nil }
                
                let pushData: Data = Data(bytes: toPush, count: toPushLen)
                toPush.deallocate()
                
                return SharedConfigMessage(
                    kind: variant.configMessageKind,
                    seqNo: seqNo,
                    data: pushData
                )
            }
    }
    
    public static func markAsPushed(messages: [SharedConfigMessage]) -> [ConfigDump.Variant: Bool] {
        messages.reduce(into: [:]) { result, message in
            let conf = SessionUtil.config(for: message.kind.configDumpVariant)
            
            // Mark the config as pushed
            config_confirm_pushed(conf.wrappedValue, message.seqNo)
            
            // Update the result to indicate whether the config needs to be dumped
            result[message.kind.configDumpVariant] = config_needs_dump(conf.wrappedValue)
        }
    }
    
    // MARK: - Receiving
    
    public static func handleConfigMessages(
        _ db: Database,
        messages: [SharedConfigMessage]
    ) throws {
        let groupedMessages: [SharedConfigMessage.Kind: [SharedConfigMessage]] = messages
            .grouped(by: \.kind)
        
        // Merge the config messages into the current state
        let results: [ConfigDump.Variant: IncomingConfResult] = groupedMessages
            .reduce(into: [:]) { result, next in
                let atomicConf = SessionUtil.config(for: next.key.configDumpVariant)
                var needsPush: Bool = false
                var needsDump: Bool = false
                let messageSentTimestamp: TimeInterval = TimeInterval(
                    (next.value.compactMap { $0.sentTimestamp }.max() ?? 0) / 1000
                )
                
                // Block the config while we are merging
                atomicConf.mutate { conf in
                    var mergeData: [UnsafePointer<CChar>?] = next.value
                        .map { message -> [CChar] in
                            message.data
                                .bytes
                                .map { CChar(bitPattern: $0) }
                        }
                        .unsafeCopy()
                    var mergeSize: [Int] = messages.map { $0.data.count }
                    config_merge(conf, &mergeData, &mergeSize, messages.count)
                    mergeData.forEach { $0?.deallocate() }
                    
                    // Get the state of this variant
                    needsPush = config_needs_push(conf)
                    needsDump = config_needs_dump(conf)
                }
                
                // Return the current state of the config
                result[next.key.configDumpVariant] = (
                    needsPush: needsPush,
                    needsDump: needsDump,
                    latestSentTimestamp: messageSentTimestamp
                )
            }
        
        // If the data needs to be dumped then apply the relevant local changes
        try results.forEach { variant, result in
            switch variant {
                case .userProfile:
                    try SessionUtil.handleUserProfileUpdate(
                        db,
                        in: .global(variant: variant),
                        needsDump: result.needsDump,
                        latestConfigUpdateSentTimestamp: result.latestSentTimestamp
                    )
            }
        }
        
    }
}
