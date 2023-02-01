// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import SessionUtil
import SessionUtilitiesKit

import Quick
import Nimble

/// This spec is designed to replicate the initial test cases for the libSession-util to ensure the behaviour matches
class ConfigConvoInfoVolatileSpec: QuickSpec {
    // MARK: - Spec

    override func spec() {
        it("generates ConvoInfoVolatileS configs correctly") {
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
            var definitelyRealId: [CChar] = "055000000000000000000000000000000000000000000000000000000000000000"
                .bytes
                .map { CChar(bitPattern: $0) }
            var oneToOne1: convo_info_volatile_1to1 = convo_info_volatile_1to1()
            expect(convo_info_volatile_get_1to1(conf, &oneToOne1, &definitelyRealId)).to(beFalse())
            expect(convo_info_volatile_size(conf)).to(equal(0))
            
            var oneToOne2: convo_info_volatile_1to1 = convo_info_volatile_1to1()
            expect(convo_info_volatile_get_or_construct_1to1(conf, &oneToOne2, definitelyRealId))
                .to(beTrue())
            
            let oneToOne2SessionId: [CChar] = withUnsafeBytes(of: oneToOne2.session_id) { [UInt8]($0) }
                .map { CChar($0) }
            expect(oneToOne2SessionId).to(equal(definitelyRealId.nullTerminated()))
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
            
            var legacyClosed1: convo_info_volatile_legacy_closed = convo_info_volatile_legacy_closed()
            var oneToOne3: convo_info_volatile_1to1 = convo_info_volatile_1to1()
            expect(convo_info_volatile_get_legacy_closed(conf, &legacyClosed1, &definitelyRealId))
                .to(beFalse())
            expect(convo_info_volatile_get_1to1(conf, &oneToOne3, &definitelyRealId)).to(beTrue())
            expect(oneToOne3.last_read).to(equal(nowTimestampMs))

            expect(config_needs_push(conf)).to(beTrue())
            expect(config_needs_dump(conf)).to(beTrue())

            var openGroupBaseUrl: [CChar] = "http://Example.ORG:5678"
                .bytes
                .map { CChar(bitPattern: $0) }
            let openGroupBaseUrlResult: [CChar] = ("http://Example.ORG:5678"
                .lowercased()
                .bytes
                .map { CChar(bitPattern: $0) } +
                [CChar](repeating: 0, count: (268 - openGroupBaseUrl.count))
            )
            var openGroupRoom: [CChar] = "SudokuRoom"
                .bytes
                .map { CChar(bitPattern: $0) }
            let openGroupRoomResult: [CChar] = ("SudokuRoom"
                .lowercased()
                .bytes
                .map { CChar(bitPattern: $0) } +
                [CChar](repeating: 0, count: (65 - openGroupRoom.count))
            )
            var openGroupPubkey: [UInt8] = Data(hex: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef")
                .bytes
            var openGroup1: convo_info_volatile_open = convo_info_volatile_open()
            expect(convo_info_volatile_get_or_construct_open(conf, &openGroup1, &openGroupBaseUrl, &openGroupRoom, &openGroupPubkey)).to(beTrue())
            expect(withUnsafeBytes(of: openGroup1.base_url) { [UInt8]($0) }
                .map { CChar($0) }
            ).to(equal(openGroupBaseUrlResult))
            expect(withUnsafeBytes(of: openGroup1.room) { [UInt8]($0) }
                .map { CChar($0) }
            ).to(equal(openGroupRoomResult))
            expect(withUnsafePointer(to: openGroup1.pubkey) { Data(bytes: $0, count: 32).toHexString() })
                .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
            openGroup1.unread = true
            
            // The new data doesn't get stored until we call this:
            convo_info_volatile_set_open(conf, &openGroup1);
            
            var toPush: UnsafeMutablePointer<UInt8>? = nil
            var toPushLen: Int = 0
            // We don't need to push since we haven't changed anything, so this call is mainly just for
            // testing:
            let seqno: Int64 = config_push(conf, &toPush, &toPushLen)
            expect(toPush).toNot(beNil())
            expect(seqno).to(equal(1))
            expect(toPushLen).to(equal(512))
            toPush?.deallocate()

            // Pretend we uploaded it
            config_confirm_pushed(conf, seqno)
            expect(config_needs_dump(conf)).to(beTrue())
            expect(config_needs_push(conf)).to(beFalse())
            
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
            expect(convo_info_volatile_get_1to1(conf2, &oneToOne4, &definitelyRealId)).to(equal(true))
            expect(oneToOne4.last_read).to(equal(nowTimestampMs))
            expect(
                withUnsafeBytes(of: oneToOne4.session_id) { [UInt8]($0) }
                    .map { CChar($0) }
                    .nullTerminated()
            ).to(equal(definitelyRealId.nullTerminated()))
            expect(oneToOne4.unread).to(beFalse())
            
            var openGroup2: convo_info_volatile_open = convo_info_volatile_open()
            expect(convo_info_volatile_get_open(conf2, &openGroup2, &openGroupBaseUrl, &openGroupRoom, &openGroupPubkey)).to(beTrue())
            expect(withUnsafeBytes(of: openGroup2.base_url) { [UInt8]($0) }
                .map { CChar($0) }
            ).to(equal(openGroupBaseUrlResult))
            expect(withUnsafeBytes(of: openGroup2.room) { [UInt8]($0) }
                .map { CChar($0) }
            ).to(equal(openGroupRoomResult))
            expect(withUnsafePointer(to: openGroup2.pubkey) { Data(bytes: $0, count: 32).toHexString() })
                .to(equal("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"))
            openGroup2.unread = true

            var anotherId: [CChar] = "051111111111111111111111111111111111111111111111111111111111111111"
                .bytes
                .map { CChar(bitPattern: $0) }
            var oneToOne5: convo_info_volatile_1to1 = convo_info_volatile_1to1()
            expect(convo_info_volatile_get_or_construct_1to1(conf2, &oneToOne5, &anotherId)).to(beTrue())
            convo_info_volatile_set_1to1(conf2, &oneToOne5)

            var thirdId: [CChar] = "05cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
                .bytes
                .map { CChar(bitPattern: $0) }
            var legacyClosed2: convo_info_volatile_legacy_closed = convo_info_volatile_legacy_closed()
            expect(convo_info_volatile_get_or_construct_legacy_closed(conf2, &legacyClosed2, &thirdId)).to(beTrue())
            legacyClosed2.last_read = (nowTimestampMs - 50)
            convo_info_volatile_set_legacy_closed(conf2, &legacyClosed2)
            expect(config_needs_push(conf2)).to(beTrue())

            var toPush2: UnsafeMutablePointer<UInt8>? = nil
            var toPush2Len: Int = 0
            let seqno2: Int64 = config_push(conf2, &toPush2, &toPush2Len)
            expect(seqno2).to(equal(2))
            
            // Check the merging
            var mergeData: [UnsafePointer<UInt8>?] = [UnsafePointer(toPush2)]
            var mergeSize: [Int] = [toPush2Len]
            expect(config_merge(conf, &mergeData, &mergeSize, 1)).to(equal(1))
            config_confirm_pushed(conf, seqno)
            toPush2?.deallocate()
            
            expect(config_needs_push(conf)).to(beFalse())

            for targetConf in [conf, conf2] {
                // Iterate through and make sure we got everything we expected
                var seen: [String] = []
                expect(convo_info_volatile_size(conf)).to(equal(4))
                expect(convo_info_volatile_size_1to1(conf)).to(equal(2))
                expect(convo_info_volatile_size_open(conf)).to(equal(1))
                expect(convo_info_volatile_size_legacy_closed(conf)).to(equal(1))
                
                var c1: convo_info_volatile_1to1 = convo_info_volatile_1to1()
                var c2: convo_info_volatile_open = convo_info_volatile_open()
                var c3: convo_info_volatile_legacy_closed = convo_info_volatile_legacy_closed()
                let it: OpaquePointer = convo_info_volatile_iterator_new(targetConf)
                
                while !convo_info_volatile_iterator_done(it) {
                    if convo_info_volatile_it_is_1to1(it, &c1) {
                        let sessionId: String = String(cString: withUnsafeBytes(of: c1.session_id) { [UInt8]($0) }
                            .map { CChar($0) }
                            .nullTerminated()
                        )
                        seen.append("1-to-1: \(sessionId)")
                    }
                    else if convo_info_volatile_it_is_open(it, &c2) {
                        let baseUrl: String = String(cString: withUnsafeBytes(of: c2.base_url) { [UInt8]($0) }
                            .map { CChar($0) }
                            .nullTerminated()
                        )
                        let room: String = String(cString: withUnsafeBytes(of: c2.room) { [UInt8]($0) }
                            .map { CChar($0) }
                            .nullTerminated()
                        )
                        
                        seen.append("og: \(baseUrl)/r/\(room)")
                    }
                    else if convo_info_volatile_it_is_legacy_closed(it, &c3) {
                        let groupId: String = String(cString: withUnsafeBytes(of: c3.group_id) { [UInt8]($0) }
                            .map { CChar($0) }
                            .nullTerminated()
                        )
                        seen.append("cl: \(groupId)")
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
            
            var fourthId: [CChar] = "052000000000000000000000000000000000000000000000000000000000000000"
                .bytes
                .map { CChar(bitPattern: $0) }
            expect(config_needs_push(conf)).to(beFalse())
            convo_info_volatile_erase_1to1(conf, &fourthId)
            expect(config_needs_push(conf)).to(beFalse())
            convo_info_volatile_erase_1to1(conf, &definitelyRealId)
            expect(config_needs_push(conf)).to(beTrue())
            expect(convo_info_volatile_size(conf)).to(equal(3))
            expect(convo_info_volatile_size_1to1(conf)).to(equal(1))

            // Check the single-type iterators:
            var seen1: [String] = []
            var c1: convo_info_volatile_1to1 = convo_info_volatile_1to1()
            let it1: OpaquePointer = convo_info_volatile_iterator_new_1to1(conf)
            
            while !convo_info_volatile_iterator_done(it1) {
                expect(convo_info_volatile_it_is_1to1(it1, &c1)).to(beTrue())
                let sessionId: String = String(cString: withUnsafeBytes(of: c1.session_id) { [UInt8]($0) }
                    .map { CChar($0) }
                    .nullTerminated()
                )
                seen1.append(sessionId)
                convo_info_volatile_iterator_advance(it1)
            }
            
            convo_info_volatile_iterator_free(it1)
            expect(seen1).to(equal([
                "051111111111111111111111111111111111111111111111111111111111111111"
            ]))
            
            var seen2: [String] = []
            var c2: convo_info_volatile_open = convo_info_volatile_open()
            let it2: OpaquePointer = convo_info_volatile_iterator_new_open(conf)
            
            while !convo_info_volatile_iterator_done(it2) {
                expect(convo_info_volatile_it_is_open(it2, &c2)).to(beTrue())
                let baseUrl: String = String(cString: withUnsafeBytes(of: c2.base_url) { [UInt8]($0) }
                    .map { CChar($0) }
                    .nullTerminated()
                )
                
                seen2.append(baseUrl)
                convo_info_volatile_iterator_advance(it2)
            }
            
            convo_info_volatile_iterator_free(it2)
            expect(seen2).to(equal([
                "http://example.org:5678"
            ]))
            
            var seen3: [String] = []
            var c3: convo_info_volatile_legacy_closed = convo_info_volatile_legacy_closed()
            let it3: OpaquePointer = convo_info_volatile_iterator_new_legacy_closed(conf)
            
            while !convo_info_volatile_iterator_done(it3) {
                expect(convo_info_volatile_it_is_legacy_closed(it3, &c3)).to(beTrue())
                let groupId: String = String(cString: withUnsafeBytes(of: c3.group_id) { [UInt8]($0) }
                    .map { CChar($0) }
                    .nullTerminated()
                )
                
                seen3.append(groupId)
                convo_info_volatile_iterator_advance(it3)
            }
            
            convo_info_volatile_iterator_free(it3)
            expect(seen3).to(equal([
                "05cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
            ]))
        }
    }
}
