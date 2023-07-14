// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import SessionUtil
import SessionUtilitiesKit

import Quick
import Nimble

/// This spec is designed to replicate the initial test cases for the libSession-util to ensure the behaviour matches
class ConfigConvoInfoVolatileSpec {
    // MARK: - Spec
    
    static func spec() {
        context("CONVO_INFO_VOLATILE") {
            it("generates config correctly") {
                let seed: Data = Data(hex: "0123456789abcdef0123456789abcdef")
                
                // FIXME: Would be good to move these into the libSession-util instead of using Sodium separately
                let identity = try! Identity.generate(from: seed)
                var edSK: [UInt8] = identity.ed25519KeyPair.secretKey
                expect(edSK.toHexString().suffix(64))
                    .to(equal("4cb76fdc6d32278e3f83dbf608360ecc6b65727934b85d2fb86862ff98c46ab7"))
                expect(identity.x25519KeyPair.publicKey.toHexString())
                    .to(equal("d2ad010eeb72d72e561d9de7bd7b6989af77dcabffa03a5111a6c859ae5c3a72"))
                expect(String(edSK.toHexString().prefix(32))).to(equal(seed.toHexString()))
                
                // Initialize a brand new, empty config because we have no dump data to deal with.
                let error: UnsafeMutablePointer<CChar>? = nil
                var conf: UnsafeMutablePointer<config_object>? = nil
                expect(convo_info_volatile_init(&conf, &edSK, nil, 0, error)).to(equal(0))
                error?.deallocate()
                
                // Empty contacts shouldn't have an existing contact
                let definitelyRealId: String = "055000000000000000000000000000000000000000000000000000000000000000"
                var cDefinitelyRealId: [CChar] = definitelyRealId.cArray.nullTerminated()
                var oneToOne1: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                expect(convo_info_volatile_get_1to1(conf, &oneToOne1, &cDefinitelyRealId)).to(beFalse())
                expect(convo_info_volatile_size(conf)).to(equal(0))
                
                var oneToOne2: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                expect(convo_info_volatile_get_or_construct_1to1(conf, &oneToOne2, &cDefinitelyRealId))
                    .to(beTrue())
                expect(String(libSessionVal: oneToOne2.session_id)).to(equal(definitelyRealId))
                expect(oneToOne2.last_read).to(equal(0))
                expect(oneToOne2.unread).to(beFalse())
                
                // No need to sync a conversation with a default state
                expect(config_needs_push(conf)).to(beFalse())
                expect(config_needs_dump(conf)).to(beFalse())
                
                // Update the last read
                let nowTimestampMs: Int64 = Int64(floor(Date().timeIntervalSince1970 * 1000))
                oneToOne2.last_read = nowTimestampMs
                
                // The new data doesn't get stored until we call this:
                convo_info_volatile_set_1to1(conf, &oneToOne2)
                
                var legacyGroup1: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
                var oneToOne3: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                expect(convo_info_volatile_get_legacy_group(conf, &legacyGroup1, &cDefinitelyRealId))
                    .to(beFalse())
                expect(convo_info_volatile_get_1to1(conf, &oneToOne3, &cDefinitelyRealId)).to(beTrue())
                expect(oneToOne3.last_read).to(equal(nowTimestampMs))
                
                expect(config_needs_push(conf)).to(beTrue())
                expect(config_needs_dump(conf)).to(beTrue())
                
                let openGroupBaseUrl: String = "http://Example.ORG:5678"
                var cOpenGroupBaseUrl: [CChar] = openGroupBaseUrl.cArray.nullTerminated()
                let openGroupBaseUrlResult: String = openGroupBaseUrl.lowercased()
                //            ("http://Example.ORG:5678"
                //                .lowercased()
                //                .cArray +
                //                [CChar](repeating: 0, count: (268 - openGroupBaseUrl.count))
                //            )
                let openGroupRoom: String = "SudokuRoom"
                var cOpenGroupRoom: [CChar] = openGroupRoom.cArray.nullTerminated()
                let openGroupRoomResult: String = openGroupRoom.lowercased()
                //            ("SudokuRoom"
                //                .lowercased()
                //                .cArray +
                //                [CChar](repeating: 0, count: (65 - openGroupRoom.count))
                //            )
                var cOpenGroupPubkey: [UInt8] = Data(hex: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
                    .bytes
                var community1: convo_info_volatile_community = convo_info_volatile_community()
                expect(convo_info_volatile_get_or_construct_community(conf, &community1, &cOpenGroupBaseUrl, &cOpenGroupRoom, &cOpenGroupPubkey)).to(beTrue())
                expect(String(libSessionVal: community1.base_url)).to(equal(openGroupBaseUrlResult))
                expect(String(libSessionVal: community1.room)).to(equal(openGroupRoomResult))
                expect(Data(libSessionVal: community1.pubkey, count: 32).toHexString())
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                community1.unread = true
                
                // The new data doesn't get stored until we call this:
                convo_info_volatile_set_community(conf, &community1);
                
                // We don't need to push since we haven't changed anything, so this call is mainly just for
                // testing:
                let pushData1: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData1.pointee.seqno).to(equal(1))
                
                // Pretend we uploaded it
                let fakeHash1: String = "fakehash1"
                var cFakeHash1: [CChar] = fakeHash1.cArray.nullTerminated()
                config_confirm_pushed(conf, pushData1.pointee.seqno, &cFakeHash1)
                expect(config_needs_dump(conf)).to(beTrue())
                expect(config_needs_push(conf)).to(beFalse())
                pushData1.deallocate()
                
                var dump1: UnsafeMutablePointer<UInt8>? = nil
                var dump1Len: Int = 0
                config_dump(conf, &dump1, &dump1Len)
                
                let error2: UnsafeMutablePointer<CChar>? = nil
                var conf2: UnsafeMutablePointer<config_object>? = nil
                expect(convo_info_volatile_init(&conf2, &edSK, dump1, dump1Len, error2)).to(equal(0))
                error2?.deallocate()
                dump1?.deallocate()
                
                expect(config_needs_dump(conf2)).to(beFalse())
                expect(config_needs_push(conf2)).to(beFalse())
                
                var oneToOne4: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                expect(convo_info_volatile_get_1to1(conf2, &oneToOne4, &cDefinitelyRealId)).to(equal(true))
                expect(oneToOne4.last_read).to(equal(nowTimestampMs))
                expect(String(libSessionVal: oneToOne4.session_id)).to(equal(definitelyRealId))
                expect(oneToOne4.unread).to(beFalse())
                
                var community2: convo_info_volatile_community = convo_info_volatile_community()
                expect(convo_info_volatile_get_community(conf2, &community2, &cOpenGroupBaseUrl, &cOpenGroupRoom)).to(beTrue())
                expect(String(libSessionVal: community2.base_url)).to(equal(openGroupBaseUrlResult))
                expect(String(libSessionVal: community2.room)).to(equal(openGroupRoomResult))
                expect(Data(libSessionVal: community2.pubkey, count: 32).toHexString())
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                community2.unread = true
                
                let anotherId: String = "051111111111111111111111111111111111111111111111111111111111111111"
                var cAnotherId: [CChar] = anotherId.cArray.nullTerminated()
                var oneToOne5: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                expect(convo_info_volatile_get_or_construct_1to1(conf2, &oneToOne5, &cAnotherId)).to(beTrue())
                oneToOne5.unread = true
                convo_info_volatile_set_1to1(conf2, &oneToOne5)
                
                let thirdId: String = "05cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
                var cThirdId: [CChar] = thirdId.cArray.nullTerminated()
                var legacyGroup2: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
                expect(convo_info_volatile_get_or_construct_legacy_group(conf2, &legacyGroup2, &cThirdId)).to(beTrue())
                legacyGroup2.last_read = (nowTimestampMs - 50)
                convo_info_volatile_set_legacy_group(conf2, &legacyGroup2)
                expect(config_needs_push(conf2)).to(beTrue())
                
                let pushData2: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData2.pointee.seqno).to(equal(2))
                
                // Check the merging
                let fakeHash2: String = "fakehash2"
                var cFakeHash2: [CChar] = fakeHash2.cArray.nullTerminated()
                var mergeHashes: [UnsafePointer<CChar>?] = [cFakeHash2].unsafeCopy()
                var mergeData: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData2.pointee.config)]
                var mergeSize: [Int] = [pushData2.pointee.config_len]
                expect(config_merge(conf, &mergeHashes, &mergeData, &mergeSize, 1)).to(equal(1))
                config_confirm_pushed(conf, pushData2.pointee.seqno, &cFakeHash2)
                pushData2.deallocate()
                
                expect(config_needs_push(conf)).to(beFalse())
                
                for targetConf in [conf, conf2] {
                    // Iterate through and make sure we got everything we expected
                    var seen: [String] = []
                    expect(convo_info_volatile_size(conf)).to(equal(4))
                    expect(convo_info_volatile_size_1to1(conf)).to(equal(2))
                    expect(convo_info_volatile_size_communities(conf)).to(equal(1))
                    expect(convo_info_volatile_size_legacy_groups(conf)).to(equal(1))
                    
                    var c1: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                    var c2: convo_info_volatile_community = convo_info_volatile_community()
                    var c3: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
                    let it: OpaquePointer = convo_info_volatile_iterator_new(targetConf)
                    
                    while !convo_info_volatile_iterator_done(it) {
                        if convo_info_volatile_it_is_1to1(it, &c1) {
                            seen.append("1-to-1: \(String(libSessionVal: c1.session_id))")
                        }
                        else if convo_info_volatile_it_is_community(it, &c2) {
                            seen.append("og: \(String(libSessionVal: c2.base_url))/r/\(String(libSessionVal: c2.room))")
                        }
                        else if convo_info_volatile_it_is_legacy_group(it, &c3) {
                            seen.append("cl: \(String(libSessionVal: c3.group_id))")
                        }
                        
                        convo_info_volatile_iterator_advance(it)
                    }
                    
                    convo_info_volatile_iterator_free(it)
                    
                    expect(seen).to(equal([
                        "1-to-1: 051111111111111111111111111111111111111111111111111111111111111111",
                        "1-to-1: 055000000000000000000000000000000000000000000000000000000000000000",
                        "og: http://example.org:5678/r/sudokuroom",
                        "cl: 05cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
                    ]))
                }
                
                let fourthId: String = "052000000000000000000000000000000000000000000000000000000000000000"
                var cFourthId: [CChar] = fourthId.cArray.nullTerminated()
                expect(config_needs_push(conf)).to(beFalse())
                convo_info_volatile_erase_1to1(conf, &cFourthId)
                expect(config_needs_push(conf)).to(beFalse())
                convo_info_volatile_erase_1to1(conf, &cDefinitelyRealId)
                expect(config_needs_push(conf)).to(beTrue())
                expect(convo_info_volatile_size(conf)).to(equal(3))
                expect(convo_info_volatile_size_1to1(conf)).to(equal(1))
                
                // Check the single-type iterators:
                var seen1: [String?] = []
                var c1: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                let it1: OpaquePointer = convo_info_volatile_iterator_new_1to1(conf)
                
                while !convo_info_volatile_iterator_done(it1) {
                    expect(convo_info_volatile_it_is_1to1(it1, &c1)).to(beTrue())
                    
                    seen1.append(String(libSessionVal: c1.session_id))
                    convo_info_volatile_iterator_advance(it1)
                }
                
                convo_info_volatile_iterator_free(it1)
                expect(seen1).to(equal([
                    "051111111111111111111111111111111111111111111111111111111111111111"
                ]))
                
                var seen2: [String?] = []
                var c2: convo_info_volatile_community = convo_info_volatile_community()
                let it2: OpaquePointer = convo_info_volatile_iterator_new_communities(conf)
                
                while !convo_info_volatile_iterator_done(it2) {
                    expect(convo_info_volatile_it_is_community(it2, &c2)).to(beTrue())
                    
                    seen2.append(String(libSessionVal: c2.base_url))
                    convo_info_volatile_iterator_advance(it2)
                }
                
                convo_info_volatile_iterator_free(it2)
                expect(seen2).to(equal([
                    "http://example.org:5678"
                ]))
                
                var seen3: [String?] = []
                var c3: convo_info_volatile_legacy_group = convo_info_volatile_legacy_group()
                let it3: OpaquePointer = convo_info_volatile_iterator_new_legacy_groups(conf)
                
                while !convo_info_volatile_iterator_done(it3) {
                    expect(convo_info_volatile_it_is_legacy_group(it3, &c3)).to(beTrue())
                    
                    seen3.append(String(libSessionVal: c3.group_id))
                    convo_info_volatile_iterator_advance(it3)
                }
                
                convo_info_volatile_iterator_free(it3)
                expect(seen3).to(equal([
                    "05cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
                ]))
            }
        }
    }
}
