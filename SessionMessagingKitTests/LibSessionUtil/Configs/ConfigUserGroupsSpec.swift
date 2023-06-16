// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import SessionUtil
import SessionUtilitiesKit
import SessionMessagingKit

import Quick
import Nimble

/// This spec is designed to replicate the initial test cases for the libSession-util to ensure the behaviour matches
class ConfigUserGroupsSpec {
    // MARK: - Spec
    
    static func spec() {
        it("parses community URLs correctly") {
            let result1 = SessionUtil.parseCommunity(url: [
                "https://example.com/",
                "SomeRoom?public_key=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
            ].joined())
            let result2 = SessionUtil.parseCommunity(url: [
                "HTTPS://EXAMPLE.COM/",
                "sOMErOOM?public_key=0123456789aBcdEF0123456789abCDEF0123456789ABCdef0123456789ABCDEF"
            ].joined())
            let result3 = SessionUtil.parseCommunity(url: [
                "HTTPS://EXAMPLE.COM/r/",
                "someroom?public_key=0123456789aBcdEF0123456789abCDEF0123456789ABCdef0123456789ABCDEF"
            ].joined())
            let result4 = SessionUtil.parseCommunity(url: [
                "http://example.com/r/",
                "someroom?public_key=0123456789aBcdEF0123456789abCDEF0123456789ABCdef0123456789ABCDEF"
            ].joined())
            let result5 = SessionUtil.parseCommunity(url: [
                "HTTPS://EXAMPLE.com:443/r/",
                "someroom?public_key=0123456789aBcdEF0123456789abCDEF0123456789ABCdef0123456789ABCDEF"
            ].joined())
            let result6 = SessionUtil.parseCommunity(url: [
                "HTTP://EXAMPLE.com:80/r/",
                "someroom?public_key=0123456789aBcdEF0123456789abCDEF0123456789ABCdef0123456789ABCDEF"
            ].joined())
            let result7 = SessionUtil.parseCommunity(url: [
                "http://example.com:80/r/",
                "someroom?public_key=ASNFZ4mrze8BI0VniavN7wEjRWeJq83vASNFZ4mrze8"
            ].joined())
            let result8 = SessionUtil.parseCommunity(url: [
                "http://example.com:80/r/",
                "someroom?public_key=yrtwk3hjixg66yjdeiuauk6p7hy1gtm8tgih55abrpnsxnpm3zzo"
            ].joined())
            
            expect(result1?.server).to(equal("https://example.com"))
            expect(result1?.server).to(equal(result2?.server))
            expect(result1?.server).to(equal(result3?.server))
            expect(result1?.server).toNot(equal(result4?.server))
            expect(result4?.server).to(equal("http://example.com"))
            expect(result1?.server).to(equal(result5?.server))
            expect(result4?.server).to(equal(result6?.server))
            expect(result4?.server).to(equal(result7?.server))
            expect(result4?.server).to(equal(result8?.server))
            expect(result1?.room).to(equal("SomeRoom"))
            expect(result2?.room).to(equal("sOMErOOM"))
            expect(result3?.room).to(equal("someroom"))
            expect(result4?.room).to(equal("someroom"))
            expect(result5?.room).to(equal("someroom"))
            expect(result6?.room).to(equal("someroom"))
            expect(result7?.room).to(equal("someroom"))
            expect(result8?.room).to(equal("someroom"))
            expect(result1?.publicKey)
                .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
            expect(result2?.publicKey)
                .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
            expect(result3?.publicKey)
                .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
            expect(result4?.publicKey)
                .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
            expect(result5?.publicKey)
                .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
            expect(result6?.publicKey)
                .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
            expect(result7?.publicKey)
                .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
            expect(result8?.publicKey)
                .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
        }
        
        context("USER_GROUPS") {
            it("generates config correctly") {
                let createdTs: Int64 = 1680064059
                let nowTs: Int64 = Int64(Date().timeIntervalSince1970)
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
                expect(user_groups_init(&conf, &edSK, nil, 0, error)).to(equal(0))
                error?.deallocate()
                
                // Empty contacts shouldn't have an existing contact
                let definitelyRealId: String = "055000000000000000000000000000000000000000000000000000000000000000"
                var cDefinitelyRealId: [CChar] = definitelyRealId.cArray.nullTerminated()
                let legacyGroup1: UnsafeMutablePointer<ugroups_legacy_group_info>? = user_groups_get_legacy_group(conf, &cDefinitelyRealId)
                expect(legacyGroup1?.pointee).to(beNil())
                expect(user_groups_size(conf)).to(equal(0))
                
                let legacyGroup2: UnsafeMutablePointer<ugroups_legacy_group_info> = user_groups_get_or_construct_legacy_group(conf, &cDefinitelyRealId)
                expect(legacyGroup2.pointee).toNot(beNil())
                expect(String(libSessionVal: legacyGroup2.pointee.session_id))
                    .to(equal(definitelyRealId))
                expect(legacyGroup2.pointee.disappearing_timer).to(equal(0))
                expect(String(libSessionVal: legacyGroup2.pointee.enc_pubkey, fixedLength: 32)).to(equal(""))
                expect(String(libSessionVal: legacyGroup2.pointee.enc_seckey, fixedLength: 32)).to(equal(""))
                expect(legacyGroup2.pointee.priority).to(equal(0))
                expect(String(libSessionVal: legacyGroup2.pointee.name)).to(equal(""))
                expect(legacyGroup2.pointee.joined_at).to(equal(0))
                expect(legacyGroup2.pointee.notifications).to(equal(CONVO_NOTIFY_DEFAULT))
                expect(legacyGroup2.pointee.mute_until).to(equal(0))
                
                // Iterate through and make sure we got everything we expected
                var membersSeen1: [String: Bool] = [:]
                var memberSessionId1: UnsafePointer<CChar>? = nil
                var memberAdmin1: Bool = false
                let membersIt1: OpaquePointer = ugroups_legacy_members_begin(legacyGroup2)
                
                while ugroups_legacy_members_next(membersIt1, &memberSessionId1, &memberAdmin1) {
                    membersSeen1[String(cString: memberSessionId1!)] = memberAdmin1
                }
                
                ugroups_legacy_members_free(membersIt1)
                
                expect(membersSeen1).to(beEmpty())
                
                // No need to sync a conversation with a default state
                expect(config_needs_push(conf)).to(beFalse())
                expect(config_needs_dump(conf)).to(beFalse())
                
                // We don't need to push since we haven't changed anything, so this call is mainly just for
                // testing:
                let pushData1: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData1.pointee.seqno).to(equal(0))
                expect([String](pointer: pushData1.pointee.obsolete, count: pushData1.pointee.obsolete_len))
                    .to(beEmpty())
                expect(pushData1.pointee.config_len).to(equal(256))
                pushData1.deallocate()
                
                let users: [String] = [
                    "050000000000000000000000000000000000000000000000000000000000000000",
                    "051111111111111111111111111111111111111111111111111111111111111111",
                    "052222222222222222222222222222222222222222222222222222222222222222",
                    "053333333333333333333333333333333333333333333333333333333333333333",
                    "054444444444444444444444444444444444444444444444444444444444444444",
                    "055555555555555555555555555555555555555555555555555555555555555555",
                    "056666666666666666666666666666666666666666666666666666666666666666"
                ]
                var cUsers: [[CChar]] = users.map { $0.cArray.nullTerminated() }
                legacyGroup2.pointee.name = "Englishmen".toLibSession()
                legacyGroup2.pointee.disappearing_timer = 60
                legacyGroup2.pointee.joined_at = createdTs
                legacyGroup2.pointee.notifications = CONVO_NOTIFY_ALL
                legacyGroup2.pointee.mute_until = (nowTs + 3600)
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[0], false)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[1], true)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[2], false)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[4], true)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[5], false)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[2], false)).to(beFalse())
                
                // Flip to and from admin
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[2], true)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup2, &cUsers[1], false)).to(beTrue())
                
                expect(ugroups_legacy_member_remove(legacyGroup2, &cUsers[5])).to(beTrue())
                expect(ugroups_legacy_member_remove(legacyGroup2, &cUsers[4])).to(beTrue())
                
                var membersSeen2: [String: Bool] = [:]
                var memberSessionId2: UnsafePointer<CChar>? = nil
                var memberAdmin2: Bool = false
                let membersIt2: OpaquePointer = ugroups_legacy_members_begin(legacyGroup2)
                
                while ugroups_legacy_members_next(membersIt2, &memberSessionId2, &memberAdmin2) {
                    membersSeen2[String(cString: memberSessionId2!)] = memberAdmin2
                }
                
                ugroups_legacy_members_free(membersIt2)
                
                expect(membersSeen2).to(equal([
                    "050000000000000000000000000000000000000000000000000000000000000000": false,
                    "051111111111111111111111111111111111111111111111111111111111111111": false,
                    "052222222222222222222222222222222222222222222222222222222222222222": true
                ]))
                
                // FIXME: Would be good to move these into the libSession-util instead of using Sodium separately
                let groupSeed: Data = Data(hex: "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")
                let groupEd25519KeyPair = Sodium().sign.keyPair(seed: groupSeed.bytes)!
                let groupX25519PublicKey = Sodium().sign.toX25519(ed25519PublicKey: groupEd25519KeyPair.publicKey)!
                
                // Note: this isn't exactly what Session actually does here for legacy closed
                // groups (rather it uses X25519 keys) but for this test the distinction doesn't matter.
                legacyGroup2.pointee.enc_pubkey = Data(groupX25519PublicKey).toLibSession()
                legacyGroup2.pointee.enc_seckey = Data(groupEd25519KeyPair.secretKey).toLibSession()
                legacyGroup2.pointee.priority = 3
                
                expect(Data(libSessionVal: legacyGroup2.pointee.enc_pubkey, count: 32).toHexString())
                    .to(equal("c5ba413c336f2fe1fb9a2c525f8a86a412a1db128a7841b4e0e217fa9eb7fd5e"))
                expect(Data(libSessionVal: legacyGroup2.pointee.enc_seckey, count: 32).toHexString())
                    .to(equal("00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"))
                
                // The new data doesn't get stored until we call this:
                user_groups_set_free_legacy_group(conf, legacyGroup2)
                
                let legacyGroup3: UnsafeMutablePointer<ugroups_legacy_group_info>? = user_groups_get_legacy_group(conf, &cDefinitelyRealId)
                expect(legacyGroup3?.pointee).toNot(beNil())
                expect(config_needs_push(conf)).to(beTrue())
                expect(config_needs_dump(conf)).to(beTrue())
                ugroups_legacy_group_free(legacyGroup3)
                
                let communityPubkey: String = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                var cCommunityPubkey: [UInt8] = Data(hex: communityPubkey).cArray
                var cCommunityBaseUrl: [CChar] = "http://Example.ORG:5678".cArray.nullTerminated()
                var cCommunityRoom: [CChar] = "SudokuRoom".cArray.nullTerminated()
                var community1: ugroups_community_info = ugroups_community_info()
                expect(user_groups_get_or_construct_community(conf, &community1, &cCommunityBaseUrl, &cCommunityRoom, &cCommunityPubkey))
                    .to(beTrue())
                
                expect(String(libSessionVal: community1.base_url)).to(equal("http://example.org:5678")) // Note: lower-case
                expect(String(libSessionVal: community1.room)).to(equal("SudokuRoom")) // Note: case-preserving
                expect(Data(libSessionVal: community1.pubkey, count: 32).toHexString())
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                community1.priority = 14
                
                // The new data doesn't get stored until we call this:
                user_groups_set_community(conf, &community1)
                
                // incremented since we made changes (this only increments once between
                // dumps; even though we changed two fields here).
                let pushData2: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData2.pointee.seqno).to(equal(1))
                expect([String](pointer: pushData2.pointee.obsolete, count: pushData2.pointee.obsolete_len))
                    .to(beEmpty())
                
                // Pretend we uploaded it
                let fakeHash1: String = "fakehash1"
                var cFakeHash1: [CChar] = fakeHash1.cArray.nullTerminated()
                config_confirm_pushed(conf, pushData2.pointee.seqno, &cFakeHash1)
                expect(config_needs_dump(conf)).to(beTrue())
                expect(config_needs_push(conf)).to(beFalse())
                
                var dump1: UnsafeMutablePointer<UInt8>? = nil
                var dump1Len: Int = 0
                config_dump(conf, &dump1, &dump1Len)
                
                let error2: UnsafeMutablePointer<CChar>? = nil
                var conf2: UnsafeMutablePointer<config_object>? = nil
                expect(user_groups_init(&conf2, &edSK, dump1, dump1Len, error2)).to(equal(0))
                error2?.deallocate()
                dump1?.deallocate()
                
                expect(config_needs_dump(conf)).to(beFalse())  // Because we just called dump() above, to load up conf2
                expect(config_needs_push(conf)).to(beFalse())
                
                let pushData3: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData3.pointee.seqno).to(equal(1))
                expect([String](pointer: pushData3.pointee.obsolete, count: pushData3.pointee.obsolete_len))
                    .to(beEmpty())
                pushData3.deallocate()
                
                let currentHashes1: UnsafeMutablePointer<config_string_list>? = config_current_hashes(conf)
                expect([String](pointer: currentHashes1?.pointee.value, count: currentHashes1?.pointee.len))
                    .to(equal(["fakehash1"]))
                currentHashes1?.deallocate()
                
                expect(config_needs_push(conf2)).to(beFalse())
                expect(config_needs_dump(conf2)).to(beFalse())
                
                let pushData4: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData4.pointee.seqno).to(equal(1))
                expect(config_needs_dump(conf2)).to(beFalse())
                expect([String](pointer: pushData4.pointee.obsolete, count: pushData4.pointee.obsolete_len))
                    .to(beEmpty())
                pushData4.deallocate()
                
                let currentHashes2: UnsafeMutablePointer<config_string_list>? = config_current_hashes(conf2)
                expect([String](pointer: currentHashes2?.pointee.value, count: currentHashes2?.pointee.len))
                    .to(equal(["fakehash1"]))
                currentHashes2?.deallocate()
                
                expect(user_groups_size(conf2)).to(equal(2))
                expect(user_groups_size_communities(conf2)).to(equal(1))
                expect(user_groups_size_legacy_groups(conf2)).to(equal(1))
                
                let legacyGroup4: UnsafeMutablePointer<ugroups_legacy_group_info>? = user_groups_get_legacy_group(conf2, &cDefinitelyRealId)
                expect(legacyGroup4?.pointee).toNot(beNil())
                expect(String(libSessionVal: legacyGroup4?.pointee.enc_pubkey, fixedLength: 32)).to(equal(""))
                expect(String(libSessionVal: legacyGroup4?.pointee.enc_seckey, fixedLength: 32)).to(equal(""))
                expect(legacyGroup4?.pointee.disappearing_timer).to(equal(60))
                expect(String(libSessionVal: legacyGroup4?.pointee.session_id)).to(equal(definitelyRealId))
                expect(legacyGroup4?.pointee.priority).to(equal(3))
                expect(String(libSessionVal: legacyGroup4?.pointee.name)).to(equal("Englishmen"))
                expect(legacyGroup4?.pointee.joined_at).to(equal(createdTs))
                expect(legacyGroup2.pointee.notifications).to(equal(CONVO_NOTIFY_ALL))
                expect(legacyGroup2.pointee.mute_until).to(equal(nowTs + 3600))
                
                var membersSeen3: [String: Bool] = [:]
                var memberSessionId3: UnsafePointer<CChar>? = nil
                var memberAdmin3: Bool = false
                let membersIt3: OpaquePointer = ugroups_legacy_members_begin(legacyGroup4)
                
                while ugroups_legacy_members_next(membersIt3, &memberSessionId3, &memberAdmin3) {
                    membersSeen3[String(cString: memberSessionId3!)] = memberAdmin3
                }
                
                ugroups_legacy_members_free(membersIt3)
                ugroups_legacy_group_free(legacyGroup4)
                
                expect(membersSeen3).to(equal([
                    "050000000000000000000000000000000000000000000000000000000000000000": false,
                    "051111111111111111111111111111111111111111111111111111111111111111": false,
                    "052222222222222222222222222222222222222222222222222222222222222222": true
                ]))
                
                expect(config_needs_push(conf2)).to(beFalse())
                expect(config_needs_dump(conf2)).to(beFalse())
                
                let pushData5: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData5.pointee.seqno).to(equal(1))
                expect(config_needs_dump(conf2)).to(beFalse())
                pushData5.deallocate()
                
                for targetConf in [conf, conf2] {
                    // Iterate through and make sure we got everything we expected
                    var seen: [String] = []
                    
                    var c1: ugroups_legacy_group_info = ugroups_legacy_group_info()
                    var c2: ugroups_community_info = ugroups_community_info()
                    let it: OpaquePointer = user_groups_iterator_new(targetConf)
                    
                    while !user_groups_iterator_done(it) {
                        if user_groups_it_is_legacy_group(it, &c1) {
                            var memberCount: Int = 0
                            var adminCount: Int = 0
                            ugroups_legacy_members_count(&c1, &memberCount, &adminCount)
                            seen.append("legacy: \(String(libSessionVal: c1.name)), \(adminCount) admins, \(memberCount) members")
                        }
                        else if user_groups_it_is_community(it, &c2) {
                            seen.append("community: \(String(libSessionVal: c2.base_url))/r/\(String(libSessionVal: c2.room))")
                        }
                        else {
                            seen.append("unknown")
                        }
                        
                        user_groups_iterator_advance(it)
                    }
                    
                    user_groups_iterator_free(it)
                    
                    expect(seen).to(equal([
                        "community: http://example.org:5678/r/SudokuRoom",
                        "legacy: Englishmen, 1 admins, 2 members"
                    ]))
                }
                
                var cCommunity2BaseUrl: [CChar] = "http://example.org:5678".cArray.nullTerminated()
                var cCommunity2Room: [CChar] = "sudokuRoom".cArray.nullTerminated()
                var community2: ugroups_community_info = ugroups_community_info()
                expect(user_groups_get_community(conf2, &community2, &cCommunity2BaseUrl, &cCommunity2Room))
                    .to(beTrue())
                expect(String(libSessionVal: community2.base_url)).to(equal("http://example.org:5678"))
                expect(String(libSessionVal: community2.room)).to(equal("SudokuRoom")) // Case preserved from the stored value, not the input value
                expect(Data(libSessionVal: community2.pubkey, count: 32).toHexString())
                    .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
                expect(community2.priority).to(equal(14))
                
                expect(config_needs_push(conf2)).to(beFalse())
                expect(config_needs_dump(conf2)).to(beFalse())
                
                let pushData6: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData6.pointee.seqno).to(equal(1))
                expect(config_needs_dump(conf2)).to(beFalse())
                pushData6.deallocate()
                
                community2.room = "sudokuRoom".toLibSession()  // Change capitalization
                user_groups_set_community(conf2, &community2)
                
                expect(config_needs_push(conf2)).to(beTrue())
                expect(config_needs_dump(conf2)).to(beTrue())
                
                let fakeHash2: String = "fakehash2"
                var cFakeHash2: [CChar] = fakeHash2.cArray.nullTerminated()
                let pushData7: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData7.pointee.seqno).to(equal(2))
                config_confirm_pushed(conf2, pushData7.pointee.seqno, &cFakeHash2)
                expect([String](pointer: pushData7.pointee.obsolete, count: pushData7.pointee.obsolete_len))
                    .to(equal([fakeHash1]))
                
                let currentHashes3: UnsafeMutablePointer<config_string_list>? = config_current_hashes(conf2)
                expect([String](pointer: currentHashes3?.pointee.value, count: currentHashes3?.pointee.len))
                    .to(equal([fakeHash2]))
                currentHashes3?.deallocate()
                
                var dump2: UnsafeMutablePointer<UInt8>? = nil
                var dump2Len: Int = 0
                config_dump(conf2, &dump2, &dump2Len)
                
                expect(config_needs_push(conf2)).to(beFalse())
                expect(config_needs_dump(conf2)).to(beFalse())
                
                let pushData8: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData8.pointee.seqno).to(equal(2))
                config_confirm_pushed(conf2, pushData8.pointee.seqno, &cFakeHash2)
                expect(config_needs_dump(conf2)).to(beFalse())
                
                var mergeHashes1: [UnsafePointer<CChar>?] = [cFakeHash2].unsafeCopy()
                var mergeData1: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData8.pointee.config)]
                var mergeSize1: [Int] = [pushData8.pointee.config_len]
                expect(config_merge(conf, &mergeHashes1, &mergeData1, &mergeSize1, 1)).to(equal(1))
                pushData8.deallocate()
                
                var cCommunity3BaseUrl: [CChar] = "http://example.org:5678".cArray.nullTerminated()
                var cCommunity3Room: [CChar] = "SudokuRoom".cArray.nullTerminated()
                var community3: ugroups_community_info = ugroups_community_info()
                expect(user_groups_get_community(conf, &community3, &cCommunity3BaseUrl, &cCommunity3Room))
                    .to(beTrue())
                expect(String(libSessionVal: community3.room)).to(equal("sudokuRoom")) // We picked up the capitalization change
                
                expect(user_groups_size(conf)).to(equal(2))
                expect(user_groups_size_communities(conf)).to(equal(1))
                expect(user_groups_size_legacy_groups(conf)).to(equal(1))
                
                let legacyGroup5: UnsafeMutablePointer<ugroups_legacy_group_info>? = user_groups_get_legacy_group(conf2, &cDefinitelyRealId)
                expect(ugroups_legacy_member_add(legacyGroup5, &cUsers[4], false)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup5, &cUsers[5], true)).to(beTrue())
                expect(ugroups_legacy_member_add(legacyGroup5, &cUsers[6], true)).to(beTrue())
                expect(ugroups_legacy_member_remove(legacyGroup5, &cUsers[1])).to(beTrue())
                
                expect(config_needs_push(conf2)).to(beFalse())
                expect(config_needs_dump(conf2)).to(beFalse())
                
                let pushData9: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData9.pointee.seqno).to(equal(2))
                expect(config_needs_dump(conf2)).to(beFalse())
                pushData9.deallocate()
                
                user_groups_set_free_legacy_group(conf2, legacyGroup5)
                expect(config_needs_push(conf2)).to(beTrue())
                expect(config_needs_dump(conf2)).to(beTrue())
                
                var cCommunity4BaseUrl: [CChar] = "http://exAMple.ORG:5678".cArray.nullTerminated()
                var cCommunity4Room: [CChar] = "sudokuROOM".cArray.nullTerminated()
                user_groups_erase_community(conf2, &cCommunity4BaseUrl, &cCommunity4Room)
                
                let fakeHash3: String = "fakehash3"
                var cFakeHash3: [CChar] = fakeHash3.cArray.nullTerminated()
                let pushData10: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                config_confirm_pushed(conf2, pushData10.pointee.seqno, &cFakeHash3)
                
                expect(pushData10.pointee.seqno).to(equal(3))
                expect([String](pointer: pushData10.pointee.obsolete, count: pushData10.pointee.obsolete_len))
                    .to(equal([fakeHash2]))
                
                let currentHashes4: UnsafeMutablePointer<config_string_list>? = config_current_hashes(conf2)
                expect([String](pointer: currentHashes4?.pointee.value, count: currentHashes4?.pointee.len))
                    .to(equal([fakeHash3]))
                currentHashes4?.deallocate()
                
                var mergeHashes2: [UnsafePointer<CChar>?] = [cFakeHash3].unsafeCopy()
                var mergeData2: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData10.pointee.config)]
                var mergeSize2: [Int] = [pushData10.pointee.config_len]
                expect(config_merge(conf, &mergeHashes2, &mergeData2, &mergeSize2, 1)).to(equal(1))
                
                expect(user_groups_size(conf)).to(equal(1))
                expect(user_groups_size_communities(conf)).to(equal(0))
                expect(user_groups_size_legacy_groups(conf)).to(equal(1))
                
                var prio: Int32 = 0
                var cBeanstalkBaseUrl: [CChar] = "http://jacksbeanstalk.org".cArray.nullTerminated()
                var cBeanstalkPubkey: [UInt8] = Data(
                    hex: "0000111122223333444455556666777788889999aaaabbbbccccddddeeeeffff"
                ).cArray
                
                ["fee", "fi", "fo", "fum"].forEach { room in
                    var cRoom: [CChar] = room.cArray.nullTerminated()
                    prio += 1
                    
                    var community4: ugroups_community_info = ugroups_community_info()
                    expect(user_groups_get_or_construct_community(conf, &community4, &cBeanstalkBaseUrl, &cRoom, &cBeanstalkPubkey))
                        .to(beTrue())
                    community4.priority = prio
                    user_groups_set_community(conf, &community4)
                }
                
                expect(user_groups_size(conf)).to(equal(5))
                expect(user_groups_size_communities(conf)).to(equal(4))
                expect(user_groups_size_legacy_groups(conf)).to(equal(1))
                
                let fakeHash4: String = "fakehash4"
                var cFakeHash4: [CChar] = fakeHash4.cArray.nullTerminated()
                let pushData11: UnsafeMutablePointer<config_push_data> = config_push(conf)
                config_confirm_pushed(conf, pushData11.pointee.seqno, &cFakeHash4)
                expect(pushData11.pointee.seqno).to(equal(4))
                expect([String](pointer: pushData11.pointee.obsolete, count: pushData11.pointee.obsolete_len))
                    .to(equal([fakeHash3, fakeHash2, fakeHash1]))
                
                // Load some obsolete ones in just to check that they get immediately obsoleted
                let fakeHash10: String = "fakehash10"
                let cFakeHash10: [CChar] = fakeHash10.cArray.nullTerminated()
                let fakeHash11: String = "fakehash11"
                let cFakeHash11: [CChar] = fakeHash11.cArray.nullTerminated()
                let fakeHash12: String = "fakehash12"
                let cFakeHash12: [CChar] = fakeHash12.cArray.nullTerminated()
                var mergeHashes3: [UnsafePointer<CChar>?] = [cFakeHash10, cFakeHash11, cFakeHash12, cFakeHash4].unsafeCopy()
                var mergeData3: [UnsafePointer<UInt8>?] = [
                    UnsafePointer(pushData10.pointee.config),
                    UnsafePointer(pushData2.pointee.config),
                    UnsafePointer(pushData7.pointee.config),
                    UnsafePointer(pushData11.pointee.config)
                ]
                var mergeSize3: [Int] = [
                    pushData10.pointee.config_len,
                    pushData2.pointee.config_len,
                    pushData7.pointee.config_len,
                    pushData11.pointee.config_len
                ]
                expect(config_merge(conf2, &mergeHashes3, &mergeData3, &mergeSize3, 4)).to(equal(4))
                expect(config_needs_dump(conf2)).to(beTrue())
                expect(config_needs_push(conf2)).to(beFalse())
                pushData2.deallocate()
                pushData7.deallocate()
                pushData10.deallocate()
                pushData11.deallocate()
                
                let currentHashes5: UnsafeMutablePointer<config_string_list>? = config_current_hashes(conf2)
                expect([String](pointer: currentHashes5?.pointee.value, count: currentHashes5?.pointee.len))
                    .to(equal([fakeHash4]))
                currentHashes5?.deallocate()
                
                let pushData12: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData12.pointee.seqno).to(equal(4))
                expect([String](pointer: pushData12.pointee.obsolete, count: pushData12.pointee.obsolete_len))
                    .to(equal([fakeHash11, fakeHash12, fakeHash10, fakeHash3]))
                pushData12.deallocate()
                
                for targetConf in [conf, conf2] {
                    // Iterate through and make sure we got everything we expected
                    var seen: [String] = []
                    
                    var c1: ugroups_legacy_group_info = ugroups_legacy_group_info()
                    var c2: ugroups_community_info = ugroups_community_info()
                    let it: OpaquePointer = user_groups_iterator_new(targetConf)
                    
                    while !user_groups_iterator_done(it) {
                        if user_groups_it_is_legacy_group(it, &c1) {
                            var memberCount: Int = 0
                            var adminCount: Int = 0
                            ugroups_legacy_members_count(&c1, &memberCount, &adminCount)
                            
                            seen.append("legacy: \(String(libSessionVal: c1.name)), \(adminCount) admins, \(memberCount) members")
                        }
                        else if user_groups_it_is_community(it, &c2) {
                            seen.append("community: \(String(libSessionVal: c2.base_url))/r/\(String(libSessionVal: c2.room))")
                        }
                        else {
                            seen.append("unknown")
                        }
                        
                        user_groups_iterator_advance(it)
                    }
                    
                    user_groups_iterator_free(it)
                    
                    expect(seen).to(equal([
                        "community: http://jacksbeanstalk.org/r/fee",
                        "community: http://jacksbeanstalk.org/r/fi",
                        "community: http://jacksbeanstalk.org/r/fo",
                        "community: http://jacksbeanstalk.org/r/fum",
                        "legacy: Englishmen, 3 admins, 2 members"
                    ]))
                }
            }
        }
    }
}
