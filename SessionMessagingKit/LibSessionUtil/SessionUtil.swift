// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtil
import SessionUtilitiesKit

/*internal*/public enum SessionUtil {    // TODO: Rename this to be cleaner?
    /*internal*/public static func loadState() {
        let storedDump: Data? = Storage.shared
            .read { db in try ConfigDump.fetchOne(db, id: .userProfile) }?
            .data
        var dump: UnsafePointer<CChar>? = nil // TODO: Load from DB/Disk
        let dumpLen: size_t = 0
        var conf: UnsafeMutablePointer<config_object>? = nil
//        var confSetup: UnsafeMutablePointer<UnsafeMutablePointer<config_object>?>? = nil
        var error: UnsafeMutablePointer<CChar>? = nil
        // TODO: Will need to manually release any unsafe pointers
        let result = user_profile_init(&conf, dump, dumpLen, error)
        
        guard result == 0 else { return }   // TODO: Throw error
        
//        var conf: UnsafeMutablePointer<config_object>? = confSetup?.pointee
        
        user_profile_set_name(conf, "TestName") // TODO: Confirm success
        
        let profileUrl: [CChar] = "http://example.org/omg-pic-123.bmp".bytes.map { CChar(bitPattern: $0) }
        let profileKey: [CChar] = "secretNOTSECRET".bytes.map { CChar(bitPattern: $0) }
        let profilePic: user_profile_pic = profileUrl.withUnsafeBufferPointer { profileUrlPtr in
            profileKey.withUnsafeBufferPointer { profileKeyPtr in
                user_profile_pic(
                    url: profileUrlPtr.baseAddress,
                    key: profileKeyPtr.baseAddress,
                    keylen: profileKey.count
                )
            }
        }
        
        user_profile_set_pic(conf, profilePic) // TODO: Confirm success
        
        if config_needs_push(conf) {
            print("Needs Push!!!")
        }
        
        if config_needs_dump(conf) {
            print("Needs Dump!!!")
        }
        
        var toPush: UnsafeMutablePointer<CChar>? = nil
        var pushLen: Int = 0
        let seqNo = config_push(conf, &toPush, &pushLen)
        
        //var remoteAddr: [CChar] = remote.bytes.map { CChar(bitPattern: $0) }
        //config_dump(conf, &dump1, &dump1len);
        
        free(toPush)    // TODO: Confirm
        
        var dumpResult: UnsafeMutablePointer<CChar>? = nil
        var dumpResultLen: Int = 0
        
        config_dump(conf, &dumpResult, &dumpResultLen)
        
        print("RAWR")
        let str = String(cString: dumpResult!)
        let stryBytes = str.bytes
        let hexStr = stryBytes.toHexString()
        let data = Data(bytes: dumpResult!, count: dumpResultLen)
//        dumpResult.
//        Storage.shared.write { db in
//            try ConfigDump(variant: .userProfile, data: <#T##Data#>)
//                .save(db)
//        }
//
        print("RAWR2")
        
        //String(cString: dumpResult!)
    }
}
