// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

/*internal*/public enum SessionUtil {
    typealias ConfResult = (needsPush: Bool, needsDump: Bool)
    
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
    
    // MARK: - UserProfile
    
    internal static func update(
        conf: UnsafeMutablePointer<config_object>?,
        with profile: Profile
    ) throws -> ConfResult {
        guard conf != nil else { throw SessionUtilError.nilConfigObject }
        
        // Update the name
        user_profile_set_name(conf, profile.name)
        
        let profilePic: user_profile_pic? = profile.profilePictureUrl?
            .bytes
            .map { CChar(bitPattern: $0) }
            .withUnsafeBufferPointer { profileUrlPtr in
                let profileKey: [CChar]? = profile.profileEncryptionKey?
                    .keyData
                    .bytes
                    .map { CChar(bitPattern: $0) }
                    
                return profileKey?.withUnsafeBufferPointer { profileKeyPtr in
                    user_profile_pic(
                        url: profileUrlPtr.baseAddress,
                        key: profileKeyPtr.baseAddress,
                        keylen: (profileKey?.count ?? 0)
                    )
                }
            }
        
        if let profilePic: user_profile_pic = profilePic {
            user_profile_set_pic(conf, profilePic)
        }
        
        return (
            needsPush: config_needs_push(conf),
            needsDump: config_needs_dump(conf)
        )
    }
}
