// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil
import SessionUtilitiesKit

public extension SessionUtil {
    enum Config {
        case object(UnsafeMutablePointer<config_object>)
        case groupKeys(
            UnsafeMutablePointer<config_group_keys>,
            info: UnsafeMutablePointer<config_object>,
            members: UnsafeMutablePointer<config_object>
        )
        
        // MARK: - Variables
        
        var needsPush: Bool {
            switch self {
                case .object(let conf): return config_needs_push(conf)
                
                case .groupKeys(let conf, _, _):
                    var pushResult: UnsafePointer<UInt8>? = nil
                    var pushResultLen: Int = 0
                    
                    return groups_keys_pending_config(conf, &pushResult, &pushResultLen)
            }
        }
        
        var needsDump: Bool {
            switch self {
                case .object(let conf): return config_needs_push(conf)
                case .groupKeys(let conf, _, _): return groups_keys_needs_dump(conf)
            }
        }
        
        var lastError: String {
            switch self {
                case .object(let conf): return String(cString: conf.pointee.last_error)
                case .groupKeys(let conf, _, _): return String(cString: conf.pointee.last_error)
            }
        }
        
        // MARK: - Functions
        
        static func from(_ conf: UnsafeMutablePointer<config_object>?) -> Config? {
            return conf.map { .object($0) }
        }
        
        static func from(
            _ conf: UnsafeMutablePointer<config_group_keys>?,
            info: UnsafeMutablePointer<config_object>,
            members: UnsafeMutablePointer<config_object>
        ) -> Config? {
            return conf.map { .groupKeys($0, info: info, members: members) }
        }
        
        func push() throws -> (data: Data, seqNo: Int64, obsoleteHashes: [String]) {
            switch self {
                case .object(let conf):
                    var cPushData: UnsafeMutablePointer<config_push_data>!
                    
                    try CExceptionHelper.performSafely {
                        cPushData = config_push(conf)
                    }
                    
                    let pushData: Data = Data(
                        bytes: cPushData.pointee.config,
                        count: cPushData.pointee.config_len
                    )
                    let obsoleteHashes: [String] = [String](
                        pointer: cPushData.pointee.obsolete,
                        count: cPushData.pointee.obsolete_len,
                        defaultValue: []
                    )
                    let seqNo: Int64 = cPushData.pointee.seqno
                    cPushData.deallocate()
                    
                    return (pushData, seqNo, obsoleteHashes)
                    
                case .groupKeys(let conf, _, _):
                    var pushResult: UnsafePointer<UInt8>!
                    var pushResultLen: Int = 0
                    
                    guard groups_keys_pending_config(conf, &pushResult, &pushResultLen) else {
                        return (Data(), 0, [])
                    }
                    
                    return (Data(bytes: pushResult, count: pushResultLen), 0, [])
            }
        }
        
        func confirmPushed(
            seqNo: Int64,
            hash: String
        ) {
            var cHash: [CChar] = hash.cArray.nullTerminated()
            
            switch self {
                case .object(let conf): return config_confirm_pushed(conf, seqNo, &cHash)
                case .groupKeys: return // No need to do anything here
            }
        }
        
        func dump() throws -> Data? {
            var dumpResult: UnsafeMutablePointer<UInt8>? = nil
            var dumpResultLen: Int = 0
            
            switch self {
                case .object(let conf):
                    try CExceptionHelper.performSafely {
                        config_dump(conf, &dumpResult, &dumpResultLen)
                    }
                    
                case .groupKeys(let conf, _, _):
                    try CExceptionHelper.performSafely {
                        groups_keys_dump(conf, &dumpResult, &dumpResultLen)
                    }
            }
            
            guard let dumpResult: UnsafeMutablePointer<UInt8> = dumpResult else { return nil }
            
            let dumpData: Data = Data(bytes: dumpResult, count: dumpResultLen)
            dumpResult.deallocate()
            
            return dumpData
        }
        
        func currentHashes() -> [String] {
            switch self {
                case .object(let conf):
                    guard let hashList: UnsafeMutablePointer<config_string_list> = config_current_hashes(conf) else {
                        return []
                    }
                    
                    let result: [String] = [String](
                        pointer: hashList.pointee.value,
                        count: hashList.pointee.len,
                        defaultValue: []
                    )
                    hashList.deallocate()
                    
                    return result
                    
                case .groupKeys(var conf): return []
            }
        }
        
        @discardableResult func merge(_ messages: [SharedConfigMessage]) -> Int {
            switch self {
                case .object(let conf):
                    var mergeHashes: [UnsafePointer<CChar>?] = messages
                        .map { message in (message.serverHash ?? "").cArray.nullTerminated() }
                        .unsafeCopy()
                    var mergeData: [UnsafePointer<UInt8>?] = messages
                        .map { message -> [UInt8] in message.data.bytes }
                        .unsafeCopy()
                    var mergeSize: [Int] = messages.map { $0.data.count }
                    let numMerged: Int32 = config_merge(
                        conf,
                        &mergeHashes,
                        &mergeData,
                        &mergeSize,
                        messages.count
                    )
                    mergeHashes.forEach { $0?.deallocate() }
                    mergeData.forEach { $0?.deallocate() }
                    
                    return Int(numMerged)
                    
                case .groupKeys(let conf, let infoConf, let membersConf):
                    return messages
                        .map { message -> Bool in
                            var data: [UInt8] = Array(message.data)
                            
                            return groups_keys_load_message(
                                conf,
                                &data,
                                data.count,
                                Int64(message.sentTimestamp ?? 0),
                                infoConf,
                                membersConf
                            )
                        }
                        .filter { $0 }
                        .count
            }
        }
    }
}

// MARK: - Optional Convenience

public extension Optional where Wrapped == SessionUtil.Config {
    // MARK: - Variables
    
    var needsPush: Bool {
        switch self {
            case .some(let config): return config.needsPush
            case .none: return false
        }
    }
    
    var needsDump: Bool {
        switch self {
            case .some(let config): return config.needsDump
            case .none: return false
        }
    }
    
    var lastError: String {
        switch self {
            case .some(let config): return config.lastError
            case .none: return "Nil Config"
        }
    }
    
    // MARK: - Functions
    
    func confirmPushed(seqNo: Int64, hash: String) {
        switch self {
            case .some(let config): return config.confirmPushed(seqNo: seqNo, hash: hash)
            case .none: return
        }
    }
    
    func dump() throws -> Data? {
        switch self {
            case .some(let config): return try config.dump()
            case .none: return nil
        }
    }
    
    func currentHashes() -> [String] {
        switch self {
            case .some(let config): return config.currentHashes()
            case .none: return []
        }
    }
    
    func merge(_ messages: [SharedConfigMessage]) {
        switch self {
            case .some(let config): config.merge(messages)
            case .none: return
        }
    }
}

// MARK: - Atomic Convenience

public extension Atomic where Value == Optional<SessionUtil.Config> {
    var needsPush: Bool { return wrappedValue.needsPush }
    var needsDump: Bool { return wrappedValue.needsDump }
}
