// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Sodium
import SessionUtil
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

extension LibSessionSpec {
    class ConfigGroupInfo {
        static func tests() {
            context("GROUP_INFO") {
                // MARK: - generates config correctly
                it("generates config correctly") {
                    let userSeed: Data = Data(hex: "0123456789abcdef0123456789abcdef")
                    let seed: Data = Data(
                        hex: "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210"
                    )
                    
                    // FIXME: Would be good to move these into the libSession-util instead of using Sodium separately
                    let keyPair: KeyPair = Crypto().generate(.ed25519KeyPair(seed: seed))!
                    var edPK: [UInt8] = keyPair.publicKey
                    var edSK: [UInt8] = keyPair.secretKey
                    
                    expect(edPK.toHexString())
                        .to(equal("cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"))
                    expect(String(Data(edSK.prefix(32)).toHexString())).to(equal(seed.toHexString()))
                    
                    // Initialize a brand new, empty config because we have no dump data to deal with.
                    var error: [CChar] = [CChar](repeating: 0, count: 256)
                    var conf: UnsafeMutablePointer<config_object>? = nil
                    expect(groups_info_init(&conf, &edPK, &edSK, nil, 0, &error)).to(equal(0))
                    
                    var conf2: UnsafeMutablePointer<config_object>? = nil
                    expect(groups_info_init(&conf2, &edPK, &edSK, nil, 0, &error)).to(equal(0))
                    
                    expect(groups_info_set_name(conf, "GROUP Name")).to(equal(0))
                    expect(config_needs_push(conf)).to(beTrue())
                    expect(config_needs_dump(conf)).to(beTrue())
                    
                    let pushData1: UnsafeMutablePointer<config_push_data> = config_push(conf)
                    expect(pushData1.pointee.seqno).to(equal(1))
                    expect(pushData1.pointee.config_len).to(equal(256))
                    expect(pushData1.pointee.obsolete_len).to(equal(0))
                    
                    let fakeHash1: String = "fakehash1"
                    var cFakeHash1: [CChar] = fakeHash1.cArray.nullTerminated()
                    config_confirm_pushed(conf, pushData1.pointee.seqno, &cFakeHash1)
                    expect(config_needs_push(conf)).to(beFalse())
                    expect(config_needs_dump(conf)).to(beTrue())
                    
                    var mergeHashes1: [UnsafePointer<CChar>?] = [cFakeHash1].unsafeCopy()
                    var mergeData1: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData1.pointee.config)]
                    var mergeSize1: [Int] = [pushData1.pointee.config_len]
                    expect(config_merge(conf2, &mergeHashes1, &mergeData1, &mergeSize1, 1)).to(equal(1))
                    expect(config_needs_push(conf2)).to(beFalse())
                    mergeHashes1.forEach { $0?.deallocate() }
                    pushData1.deallocate()
                    
                    let namePtr: UnsafePointer<CChar>? = groups_info_get_name(conf2)
                    expect(namePtr).toNot(beNil())
                    expect(String(cString: namePtr!)).to(equal("GROUP Name"))
                    
                    let createTime: Int64 = 1682529839
                    let pic: user_profile_pic = user_profile_pic(
                        url: "http://example.com/12345".toLibSession(),
                        key: Data(hex: "abcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcdabcd")
                            .toLibSession()
                    )
                    expect(groups_info_set_pic(conf, pic)).to(equal(0))
                    groups_info_set_expiry_timer(conf, 60 * 60)
                    groups_info_set_created(conf, createTime)
                    groups_info_set_delete_before(conf, createTime + (50 * 86400))
                    groups_info_set_attach_delete_before(conf, createTime + (70 * 86400))
                    groups_info_destroy_group(conf)
                    
                    let pushData2: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                    let obsoleteHashes: [String] = [String](
                        pointer: pushData2.pointee.obsolete,
                        count: pushData2.pointee.obsolete_len,
                        defaultValue: []
                    )
                    expect(pushData2.pointee.seqno).to(equal(2))
                    expect(pushData2.pointee.config_len).to(equal(512))
                    expect(obsoleteHashes).to(equal(["fakehash1"]))
                    
                    let fakeHash2: String = "fakehash2"
                    var cFakeHash2: [CChar] = fakeHash2.cArray.nullTerminated()
                    config_confirm_pushed(conf2, pushData2.pointee.seqno, &cFakeHash2)
                    
                    expect(groups_info_set_name(conf, "Better name!")).to(equal(0))
                    
                    // This fails because ginfo1 doesn't yet have the new key that ginfo2 used (bbb...)
                    var mergeHashes2: [UnsafePointer<CChar>?] = [cFakeHash2].unsafeCopy()
                    var mergeData2: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData2.pointee.config)]
                    var mergeSize2: [Int] = [pushData2.pointee.config_len]
                    expect(config_merge(conf, &mergeHashes2, &mergeData2, &mergeSize2, 1)).to(equal(0))
                    mergeHashes2.forEach { $0?.deallocate() }
                    mergeData2.forEach { $0?.deallocate() }
                }
            }
        }
    }
}
