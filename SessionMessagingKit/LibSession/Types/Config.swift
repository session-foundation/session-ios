// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.
//
// stringlint:disable

import Foundation
import SessionUtil
import SessionSnodeKit
import SessionUtilitiesKit

public extension LibSession {
    typealias UserConfigInitialiser = (
        UnsafeMutablePointer<UnsafeMutablePointer<config_object>?>?,    // conf
        UnsafePointer<UInt8>?,                                          // ed25519_secretkey
        UnsafePointer<UInt8>?,                                          // dump
        Int,                                                            // dumplen
        UnsafeMutablePointer<CChar>?                                    // error
    ) -> Int32
    typealias GroupConfigInitialiser = (
        UnsafeMutablePointer<UnsafeMutablePointer<config_object>?>?,    // conf
        UnsafePointer<UInt8>?,                                          // ed25519_pubkey
        UnsafePointer<UInt8>?,                                          // ed25519_secretkey
        UnsafePointer<UInt8>?,                                          // dump
        Int,                                                            // dumplen
        UnsafeMutablePointer<CChar>?                                    // error
    ) -> Int32
    typealias ConfigSizeInfo = (UnsafePointer<config_object>?) -> Int
    
    // MARK: - Config
    
    enum Config {
        case userProfile(UnsafeMutablePointer<config_object>)
        case contacts(UnsafeMutablePointer<config_object>)
        case convoInfoVolatile(UnsafeMutablePointer<config_object>)
        case userGroups(UnsafeMutablePointer<config_object>)
        case local(UnsafeMutablePointer<config_object>)
        
        case groupInfo(UnsafeMutablePointer<config_object>)
        case groupMembers(UnsafeMutablePointer<config_object>)
        case groupKeys(
            UnsafeMutablePointer<config_group_keys>,
            info: UnsafeMutablePointer<config_object>,
            members: UnsafeMutablePointer<config_object>
        )
        
        // MARK: - Variables
        
        var variant: ConfigDump.Variant {
            switch self {
                case .userProfile: return .userProfile
                case .contacts: return .contacts
                case .convoInfoVolatile: return .convoInfoVolatile
                case .userGroups: return .userGroups
                case .local: return .local
                    
                case .groupInfo: return .groupInfo
                case .groupMembers: return .groupMembers
                case .groupKeys: return .groupKeys
            }
        }
        
        var count: Int {
            switch self {
                case .userProfile: return 1
                case .contacts(let conf): return contacts_size(conf)
                case .convoInfoVolatile(let conf): return convo_info_volatile_size(conf)
                case .userGroups(let conf): return user_groups_size(conf)
                case .local(let conf): return local_size_settings(conf)
                
                case .groupInfo: return 1
                case .groupMembers(let conf): return groups_members_size(conf)
                case .groupKeys(let conf, _, _): return groups_keys_size(conf)
            }
        }
        
        var countDescription: String {
            switch self {
                case .userProfile: return "\(count) profile"
                case .contacts: return "\(count) contacts"
                case .userGroups: return "\(count) group conversations"
                case .convoInfoVolatile: return "\(count) volatile conversations"
                case .local: return "\(count) settings"
                    
                case .groupInfo: return "\(count) group info"
                case .groupMembers: return "\(count) group members"
                case .groupKeys: return "\(count) group keys"
            }
        }
        
        var needsPush: Bool {
            switch self {
                case .userProfile(let conf), .contacts(let conf), .convoInfoVolatile(let conf),
                    .userGroups(let conf), .local(let conf), .groupInfo(let conf), .groupMembers(let conf):
                    return config_needs_push(conf)
                
                case .groupKeys(let conf, _, _):
                    var pushResult: UnsafePointer<UInt8>? = nil
                    var pushResultLen: Int = 0
                    
                    return groups_keys_pending_config(conf, &pushResult, &pushResultLen)
            }
        }
        
        private var lastErrorString: String? {
            switch self {
                case .userProfile(let conf), .contacts(let conf), .convoInfoVolatile(let conf),
                    .userGroups(let conf), .local(let conf), .groupInfo(let conf), .groupMembers(let conf):
                    guard conf.pointee.last_error != nil else { return nil }
                    
                    return String(cString: conf.pointee.last_error)
                    
                case .groupKeys(let conf, _, _):
                    guard conf.pointee.last_error != nil else { return nil }
                    
                    return String(cString: conf.pointee.last_error)
            }
        }
        
        var lastError: LibSessionError? {
            guard
                let errorString: String = lastErrorString,
                !errorString.isEmpty
            else { return nil }
            
            return LibSessionError.libSessionError(errorString)
        }
        
        // MARK: - Functions
        
        func push(variant: ConfigDump.Variant) throws -> PendingPushes? {
            switch self {
                case .userProfile(let conf), .contacts(let conf), .convoInfoVolatile(let conf),
                    .userGroups(let conf), .local(let conf), .groupInfo(let conf), .groupMembers(let conf):
                    /// The `config_push` function implicitly unwraps it's value but can throw internally so call it in a guard
                    /// statement to prevent the implicit unwrap from causing a crash (ideally it would return a standard optional
                    /// so the compiler would warn us but it's not that straight forward when dealing with C)
                    guard let cPushData: UnsafeMutablePointer<config_push_data> = config_push(conf) else {
                        throw LibSessionError(
                            self,
                            fallbackError: .unableToGeneratePushData,
                            logMessage: "Failed to generate push data for \(variant) config data, size: \(countDescription), error"
                        )
                    }
                    
                    let allPushData: [Data] = (0..<cPushData.pointee.n_configs)
                        .reduce(into: []) { result, i in
                            guard let configPtr = cPushData.pointee.config[i] else { return }
                            
                            result.append(
                                Data(
                                    bytes: configPtr,
                                    count: cPushData.pointee.config_lens[i]
                                )
                            )
                        }
                    let obsoleteHashes: [String] = [String](
                        cStringArray: cPushData.pointee.obsolete,
                        count: cPushData.pointee.obsolete_len
                    ).defaulting(to: [])
                    let seqNo: Int64 = cPushData.pointee.seqno
                    free(UnsafeMutableRawPointer(mutating: cPushData))
                    
                    return PendingPushes(
                        pushData: PendingPushes.PushData(
                            data: allPushData,
                            seqNo: seqNo,
                            variant: variant
                        ),
                        obsoleteHashes: Set(obsoleteHashes)
                    )
                    
                case .groupKeys(let conf, _, _):
                    var pushResult: UnsafePointer<UInt8>!
                    var pushResultLen: Int = 0
                    
                    guard groups_keys_pending_config(conf, &pushResult, &pushResultLen) else { return nil }
                    
                    return PendingPushes(
                        pushData: PendingPushes.PushData(
                            data: [Data(bytes: pushResult, count: pushResultLen)],
                            seqNo: 0,
                            variant: variant
                        )
                    )
            }
        }
        
        func confirmPushed(
            seqNo: Int64,
            hashes: [String]
        ) throws {
            switch self {
                case .userProfile(let conf), .contacts(let conf), .convoInfoVolatile(let conf),
                    .userGroups(let conf), .local(let conf), .groupInfo(let conf), .groupMembers(let conf):
                    try hashes.withUnsafeCStrArray { cHashes in
                        config_confirm_pushed(
                            conf,
                            seqNo,
                            cHashes.baseAddress,
                            cHashes.count
                        )
                    }
                    
                case .groupKeys: return // No need to do anything here
            }
        }
        
        func dump() throws -> Data? {
            var dumpResult: UnsafeMutablePointer<UInt8>? = nil
            var dumpResultLen: Int = 0
            
            switch self {
                case .userProfile(let conf), .contacts(let conf), .convoInfoVolatile(let conf),
                    .userGroups(let conf), .local(let conf), .groupInfo(let conf), .groupMembers(let conf):
                    config_dump(conf, &dumpResult, &dumpResultLen)
                case .groupKeys(let conf, _, _): groups_keys_dump(conf, &dumpResult, &dumpResultLen)
            }
            
            // If we got an error then throw it
            try LibSessionError.throwIfNeeded(self)
            
            guard let dumpResult: UnsafeMutablePointer<UInt8> = dumpResult else { return nil }
            
            let dumpData: Data = Data(bytes: dumpResult, count: dumpResultLen)
            free(UnsafeMutableRawPointer(mutating: dumpResult))
            
            return dumpData
        }
        
        func activeHashes() -> [String] {
            switch self {
                case .userProfile(let conf), .contacts(let conf), .convoInfoVolatile(let conf),
                    .userGroups(let conf), .local(let conf), .groupInfo(let conf), .groupMembers(let conf):
                    guard let hashList: UnsafeMutablePointer<config_string_list> = config_active_hashes(conf) else {
                        return []
                    }
                    
                    let result: [String] = [String](
                        cStringArray: hashList.pointee.value,
                        count: hashList.pointee.len
                    ).defaulting(to: [])
                    free(UnsafeMutableRawPointer(mutating: hashList))
                    
                    return result
                    
                case .groupKeys(let conf, _, _):
                    guard let hashList: UnsafeMutablePointer<config_string_list> = groups_keys_active_hashes(conf) else {
                        return []
                    }
                    
                    let result: [String] = [String](
                        cStringArray: hashList.pointee.value,
                        count: hashList.pointee.len
                    ).defaulting(to: [])
                    free(UnsafeMutableRawPointer(mutating: hashList))
                    
                    return result
            }
        }
        
        func merge(_ messages: [ConfigMessageReceiveJob.Details.MessageInfo]) throws -> Int64? {
            switch self {
                case .userProfile(let conf), .contacts(let conf), .convoInfoVolatile(let conf),
                    .userGroups(let conf), .local(let conf), .groupInfo(let conf), .groupMembers(let conf):
                    return try messages.map { $0.serverHash }.withUnsafeCStrArray { cMergeHashes in
                        try messages.map { Array($0.data) }.withUnsafeUInt8CArray { cMergeData in
                            let mergeSize: [size_t] = messages.map { size_t($0.data.count) }
                            let mergedHashesPtr: UnsafeMutablePointer<config_string_list>? = config_merge(
                                conf,
                                cMergeHashes.baseAddress,
                                cMergeData.baseAddress,
                                mergeSize,
                                messages.count
                            )
                            
                            // If we got an error then throw it
                            try LibSessionError.throwIfNeeded(conf)
                            
                            // Get the list of hashes from the config (to determine which were successful)
                            let mergedHashes: [String] = mergedHashesPtr
                                .map { ptr in
                                    [String](cStringArray: ptr.pointee.value, count: ptr.pointee.len)
                                        .defaulting(to: [])
                                }
                                .defaulting(to: [])
                            free(UnsafeMutableRawPointer(mutating: mergedHashesPtr))
                            
                            if mergedHashes.count != messages.count {
                                Log.warn(.libSession, "Unable to merge \(messages[0].namespace) messages (\(mergedHashes.count)/\(messages.count))")
                            }
                            
                            return messages
                                .filter { mergedHashes.contains($0.serverHash) }
                                .map { $0.serverTimestampMs }
                                .sorted()
                                .last
                        }
                    }
                    
                case .groupKeys(let conf, let infoConf, let membersConf):
                    let successfulMergeTimestamps: [Int64] = try messages
                        .map { message -> (Bool, Int64) in
                            var data: [UInt8] = Array(message.data)
                            var cServerHash: [CChar] = try message.serverHash.cString(using: .utf8) ?? {
                                throw LibSessionError.invalidCConversion
                            }()
                            
                            let result: Bool = groups_keys_load_message(
                                conf,
                                &cServerHash,
                                &data,
                                data.count,
                                message.serverTimestampMs,
                                infoConf,
                                membersConf
                            )
                            
                            // If we got an error then throw it
                            try LibSessionError.throwIfNeeded(conf)
                            
                            return (result, message.serverTimestampMs)
                        }
                        .filter { success, _ in success }
                        .map { _, serverTimestampMs in serverTimestampMs }
                        .sorted()
                    
                    if successfulMergeTimestamps.count != messages.count {
                        Log.warn(.libSession, "Unable to merge \(SnodeAPI.Namespace.configGroupKeys) messages (\(successfulMergeTimestamps.count)/\(messages.count))")
                    }
                    
                    return successfulMergeTimestamps.last
            }
        }
    }
}

// MARK: - PendingPushes

public extension LibSession {
    struct PendingPushes {
        public struct PushData {
            let data: [Data]
            let seqNo: Int64
            let variant: ConfigDump.Variant
        }
        
        var pushData: [PushData]
        var obsoleteHashes: Set<String>
        
        init(pushData: [PushData] = [], obsoleteHashes: Set<String> = []) {
            self.pushData = pushData
            self.obsoleteHashes = obsoleteHashes
        }
        
        init(pushData: PushData, obsoleteHashes: Set<String> = []) {
            self.pushData = [pushData]
            self.obsoleteHashes = obsoleteHashes
        }
        
        mutating func append(_ data: PendingPushes?) {
            guard let data: PendingPushes = data else { return }
            
            pushData.append(contentsOf: data.pushData)
            obsoleteHashes.insert(contentsOf: data.obsoleteHashes)
        }
        
        mutating func append(data: PushData? = nil, hashes: [String] = []) {
            if let data: PushData = data {
                pushData.append(data)
            }
            
            if !hashes.isEmpty {
                obsoleteHashes.insert(contentsOf: Set(hashes))
            }
        }
        
        mutating func append(contentsOf data: [PushData], hashes: [String] = []) {
            pushData.append(contentsOf: data)
            obsoleteHashes.insert(contentsOf: Set(hashes))
        }
    }
}

// MARK: - LibSessionError Convenience

public extension LibSessionError {
    init(
        _ config: LibSession.Config?,
        fallbackError: LibSessionError,
        logMessage: String? = nil
    ) {
        switch config {
            case .none:
                self = fallbackError
                
                if let logMessage: String = logMessage {
                    Log.error("\(logMessage): \(self)")
                }
                
            case .userProfile(let conf), .contacts(let conf), .convoInfoVolatile(let conf),
                .userGroups(let conf), .local(let conf), .groupInfo(let conf), .groupMembers(let conf):
                self = LibSessionError(conf, fallbackError: fallbackError, logMessage: logMessage)
            case .groupKeys(let conf, _, _): self = LibSessionError(conf, fallbackError: fallbackError, logMessage: logMessage)
        }
    }
    
    static func throwIfNeeded(_ config: LibSession.Config?) throws {
        switch config {
            case .none: return
            case .userProfile(let conf), .contacts(let conf), .convoInfoVolatile(let conf),
                .userGroups(let conf), .local(let conf), .groupInfo(let conf), .groupMembers(let conf):
                try LibSessionError.throwIfNeeded(conf)
            case .groupKeys(let conf, _, _): try LibSessionError.throwIfNeeded(conf)
        }
    }
}

// MARK: - Formatting

public extension String.StringInterpolation {
    mutating func appendInterpolation(_ error: LibSessionError?) {
        appendLiteral(error.map { "\($0)" } ?? "Unknown Error")
    }
}
