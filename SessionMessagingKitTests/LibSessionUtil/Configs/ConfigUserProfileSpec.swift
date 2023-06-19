// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import SessionUtil
import SessionUtilitiesKit
import SessionMessagingKit

import Quick
import Nimble

/// This spec is designed to replicate the initial test cases for the libSession-util to ensure the behaviour matches
class ConfigUserProfileSpec {
    // MARK: - Spec
    
    static func spec() {
        context("USER_PROFILE") {
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
                expect(user_profile_init(&conf, &edSK, nil, 0, error)).to(equal(0))
                error?.deallocate()
                
                // We don't need to push anything, since this is an empty config
                expect(config_needs_push(conf)).to(beFalse())
                // And we haven't changed anything so don't need to dump to db
                expect(config_needs_dump(conf)).to(beFalse())
                
                // Since it's empty there shouldn't be a name.
                let namePtr: UnsafePointer<CChar>? = user_profile_get_name(conf)
                expect(namePtr).to(beNil())
                
                // We don't need to push since we haven't changed anything, so this call is mainly just for
                // testing:
                let pushData1: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData1.pointee).toNot(beNil())
                expect(pushData1.pointee.seqno).to(equal(0))
                expect(pushData1.pointee.config_len).to(equal(256))
                
                let encDomain: [CChar] = "UserProfile"
                    .bytes
                    .map { CChar(bitPattern: $0) }
                expect(String(cString: config_encryption_domain(conf))).to(equal("UserProfile"))
                
                var toPushDecSize: Int = 0
                let toPushDecrypted: UnsafeMutablePointer<UInt8>? = config_decrypt(pushData1.pointee.config, pushData1.pointee.config_len, edSK, encDomain, &toPushDecSize)
                let prefixPadding: String = (0..<193)
                    .map { _ in "\0" }
                    .joined()
                expect(toPushDecrypted).toNot(beNil())
                expect(toPushDecSize).to(equal(216))  // 256 - 40 overhead
                expect(String(pointer: toPushDecrypted, length: toPushDecSize))
                    .to(equal("\(prefixPadding)d1:#i0e1:&de1:<le1:=dee"))
                pushData1.deallocate()
                toPushDecrypted?.deallocate()
                
                // This should also be unset:
                let pic: user_profile_pic = user_profile_get_pic(conf)
                expect(String(libSessionVal: pic.url)).to(beEmpty())
                
                // Now let's go set a profile name and picture:
                expect(user_profile_set_name(conf, "Kallie")).to(equal(0))
                let p: user_profile_pic = user_profile_pic(
                    url: "http://example.org/omg-pic-123.bmp".toLibSession(),
                    key: "secret78901234567890123456789012".data(using: .utf8)!.toLibSession()
                )
                expect(user_profile_set_pic(conf, p)).to(equal(0))
                user_profile_set_nts_priority(conf, 9)
                
                // Retrieve them just to make sure they set properly:
                let namePtr2: UnsafePointer<CChar>? = user_profile_get_name(conf)
                expect(namePtr2).toNot(beNil())
                expect(String(cString: namePtr2!)).to(equal("Kallie"))
                
                let pic2: user_profile_pic = user_profile_get_pic(conf);
                expect(String(libSessionVal: pic2.url)).to(equal("http://example.org/omg-pic-123.bmp"))
                expect(Data(libSessionVal: pic2.key, count: ProfileManager.avatarAES256KeyByteLength))
                    .to(equal("secret78901234567890123456789012".data(using: .utf8)))
                expect(user_profile_get_nts_priority(conf)).to(equal(9))
                
                // Since we've made changes, we should need to push new config to the swarm, *and* should need
                // to dump the updated state:
                expect(config_needs_push(conf)).to(beTrue())
                expect(config_needs_dump(conf)).to(beTrue())
                
                // incremented since we made changes (this only increments once between
                // dumps; even though we changed two fields here).
                let pushData2: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData2.pointee.seqno).to(equal(1))
                
                // Note: This hex value differs from the value in the library tests because
                // it looks like the library has an "end of cell mark" character added at the
                // end (0x07 or '0007') so we need to manually add it to work
                let expHash0: [UInt8] = Data(hex: "ea173b57beca8af18c3519a7bbf69c3e7a05d1c049fa9558341d8ebb48b0c965")
                    .bytes
                // The data to be actually pushed, expanded like this to make it somewhat human-readable:
                let expPush1Decrypted: [UInt8] = ["""
                    d
                      1:#i1e
                      1:& d
                        1:+ i9e
                        1:n 6:Kallie
                        1:p 34:http://example.org/omg-pic-123.bmp
                        1:q 32:secret78901234567890123456789012
                      e
                      1:< l
                        l i0e 32:
                """.removeCharacters(characterSet: CharacterSet.whitespacesAndNewlines) // For readability
                    .bytes,
                                                  expHash0,
                """
                de e
                      e
                      1:= d
                        1:+ 0:
                        1:n 0:
                        1:p 0:
                        1:q 0:
                      e
                    e
                """.removeCharacters(characterSet: CharacterSet.whitespacesAndNewlines) // For readability
                    .bytes
                ].flatMap { $0 }
                let expPush1Encrypted: [UInt8] = Data(hex: [
                    "9693a69686da3055f1ecdfb239c3bf8e746951a36d888c2fb7c02e856a5c2091b24e39a7e1af828f",
                    "1fa09fe8bf7d274afde0a0847ba143c43ffb8722301b5ae32e2f078b9a5e19097403336e50b18c84",
                    "aade446cd2823b011f97d6ad2116a53feb814efecc086bc172d31f4214b4d7c630b63bbe575b0868",
                    "2d146da44915063a07a78556ab5eff4f67f6aa26211e8d330b53d28567a931028c393709a325425d",
                    "e7486ccde24416a7fd4a8ba5fa73899c65f4276dfaddd5b2100adcf0f793104fb235b31ce32ec656",
                    "056009a9ebf58d45d7d696b74e0c7ff0499c4d23204976f19561dc0dba6dc53a2497d28ce03498ea",
                    "49bf122762d7bc1d6d9c02f6d54f8384"
                ].joined()).bytes
                
                let pushData2Str: String = String(pointer: pushData2.pointee.config, length: pushData2.pointee.config_len, encoding: .ascii)!
                let expPush1EncryptedStr: String = String(pointer: expPush1Encrypted, length: expPush1Encrypted.count, encoding: .ascii)!
                expect(pushData2Str).to(equal(expPush1EncryptedStr))
                
                // Raw decryption doesn't unpad (i.e. the padding is part of the encrypted data)
                var pushData2DecSize: Int = 0
                let pushData2Decrypted: UnsafeMutablePointer<UInt8>? = config_decrypt(
                    pushData2.pointee.config,
                    pushData2.pointee.config_len,
                    edSK,
                    encDomain,
                    &pushData2DecSize
                )
                let prefixPadding2: String = (0..<(256 - 40 - expPush1Decrypted.count))
                    .map { _ in "\0" }
                    .joined()
                expect(pushData2DecSize).to(equal(216))  // 256 - 40 overhead
                
                let pushData2DecryptedStr: String = String(pointer: pushData2Decrypted, length: pushData2DecSize, encoding: .ascii)!
                let expPush1DecryptedStr: String = String(pointer: expPush1Decrypted, length: expPush1Decrypted.count, encoding: .ascii)
                    .map { "\(prefixPadding2)\($0)" }!
                expect(pushData2DecryptedStr).to(equal(expPush1DecryptedStr))
                pushData2Decrypted?.deallocate()
                
                // We haven't dumped, so still need to dump:
                expect(config_needs_dump(conf)).to(beTrue())
                // We did call push, but we haven't confirmed it as stored yet, so this will still return true:
                expect(config_needs_push(conf)).to(beTrue())
                
                var dump1: UnsafeMutablePointer<UInt8>? = nil
                var dump1Len: Int = 0
                
                config_dump(conf, &dump1, &dump1Len)
                // (in a real client we'd now store this to disk)
                
                expect(config_needs_dump(conf)).to(beFalse())
                
                let expDump1: [CChar] = [
                    """
                        d
                          1:! i2e
                          1:$ \(expPush1Decrypted.count):
                    """
                        .removeCharacters(characterSet: CharacterSet.whitespacesAndNewlines)
                        .bytes
                        .map { CChar(bitPattern: $0) },
                    expPush1Decrypted
                        .map { CChar(bitPattern: $0) },
                    """
                          1:(0:
                          1:)le
                        e
                    """.removeCharacters(characterSet: CharacterSet.whitespacesAndNewlines)
                        .bytes
                        .map { CChar(bitPattern: $0) }
                ].flatMap { $0 }
                expect(String(pointer: dump1, length: dump1Len, encoding: .ascii))
                    .to(equal(String(pointer: expDump1, length: expDump1.count, encoding: .ascii)))
                dump1?.deallocate()
                
                // So now imagine we got back confirmation from the swarm that the push has been stored:
                let fakeHash1: String = "fakehash1"
                var cFakeHash1: [CChar] = fakeHash1.cArray.nullTerminated()
                config_confirm_pushed(conf, pushData2.pointee.seqno, &cFakeHash1)
                pushData2.deallocate()
                
                expect(config_needs_push(conf)).to(beFalse())
                expect(config_needs_dump(conf)).to(beTrue()) // The confirmation changes state, so this makes us need a dump
                
                var dump2: UnsafeMutablePointer<UInt8>? = nil
                var dump2Len: Int = 0
                config_dump(conf, &dump2, &dump2Len)
                
                let expDump2: [CChar] = [
                    """
                        d
                          1:! i0e
                          1:$ \(expPush1Decrypted.count):
                    """
                        .removeCharacters(characterSet: CharacterSet.whitespacesAndNewlines)
                        .bytes
                        .map { CChar(bitPattern: $0) },
                    expPush1Decrypted
                        .map { CChar(bitPattern: $0) },
                    """
                          1:(9:fakehash1
                          1:)le
                        e
                    """.removeCharacters(characterSet: CharacterSet.whitespacesAndNewlines)
                        .bytes
                        .map { CChar(bitPattern: $0) }
                ].flatMap { $0 }
                expect(String(pointer: dump2, length: dump2Len, encoding: .ascii))
                    .to(equal(String(pointer: expDump2, length: expDump2.count, encoding: .ascii)))
                dump2?.deallocate()
                expect(config_needs_dump(conf)).to(beFalse())
                
                // Now we're going to set up a second, competing config object (in the real world this would be
                // another Session client somewhere).
                
                // Start with an empty config, as above:
                let error2: UnsafeMutablePointer<CChar>? = nil
                var conf2: UnsafeMutablePointer<config_object>? = nil
                expect(user_profile_init(&conf2, &edSK, nil, 0, error2)).to(equal(0))
                expect(config_needs_dump(conf2)).to(beFalse())
                error2?.deallocate()
                
                // Now imagine we just pulled down the `exp_push1` string from the swarm; we merge it into
                // conf2:
                var mergeHashes: [UnsafePointer<CChar>?] = [cFakeHash1].unsafeCopy()
                var mergeData: [UnsafePointer<UInt8>?] = [expPush1Encrypted].unsafeCopy()
                var mergeSize: [Int] = [expPush1Encrypted.count]
                expect(config_merge(conf2, &mergeHashes, &mergeData, &mergeSize, 1)).to(equal(1))
                mergeHashes.forEach { $0?.deallocate() }
                mergeData.forEach { $0?.deallocate() }
                
                // Our state has changed, so we need to dump:
                expect(config_needs_dump(conf2)).to(beTrue())
                var dump3: UnsafeMutablePointer<UInt8>? = nil
                var dump3Len: Int = 0
                config_dump(conf2, &dump3, &dump3Len)
                // (store in db)
                dump3?.deallocate()
                expect(config_needs_dump(conf2)).to(beFalse())
                
                // We *don't* need to push: even though we updated, all we did is update to the merged data (and
                // didn't have any sort of merge conflict needed):
                expect(config_needs_push(conf2)).to(beFalse())
                
                // Now let's create a conflicting update:
                
                // Change the name on both clients:
                user_profile_set_name(conf, "Nibbler")
                user_profile_set_name(conf2, "Raz")
                
                // And, on conf2, we're also going to change the profile pic:
                let p2: user_profile_pic = user_profile_pic(
                    url: "http://new.example.com/pic".toLibSession(),
                    key: "qwert\0yuio1234567890123456789012".data(using: .utf8)!.toLibSession()
                )
                user_profile_set_pic(conf2, p2)
                
                // Both have changes, so push need a push
                expect(config_needs_push(conf)).to(beTrue())
                expect(config_needs_push(conf2)).to(beTrue())
                
                let fakeHash2: String = "fakehash2"
                var cFakeHash2: [CChar] = fakeHash2.cArray.nullTerminated()
                let pushData3: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData3.pointee.seqno).to(equal(2)) // incremented, since we made a field change
                config_confirm_pushed(conf, pushData3.pointee.seqno, &cFakeHash2)
                
                let fakeHash3: String = "fakehash3"
                var cFakeHash3: [CChar] = fakeHash3.cArray.nullTerminated()
                let pushData4: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData4.pointee.seqno).to(equal(2)) // incremented, since we made a field change
                config_confirm_pushed(conf, pushData4.pointee.seqno, &cFakeHash3)
                
                var dump4: UnsafeMutablePointer<UInt8>? = nil
                var dump4Len: Int = 0
                config_dump(conf, &dump4, &dump4Len);
                var dump5: UnsafeMutablePointer<UInt8>? = nil
                var dump5Len: Int = 0
                config_dump(conf2, &dump5, &dump5Len);
                // (store in db)
                dump4?.deallocate()
                dump5?.deallocate()
                
                // Since we set different things, we're going to get back different serialized data to be
                // pushed:
                let pushData3Str: String? = String(pointer: pushData3.pointee.config, length: pushData3.pointee.config_len, encoding: .ascii)
                let pushData4Str: String? = String(pointer: pushData4.pointee.config, length: pushData4.pointee.config_len, encoding: .ascii)
                expect(pushData3Str).toNot(equal(pushData4Str))
                
                // Now imagine that each client pushed its `seqno=2` config to the swarm, but then each client
                // also fetches new messages and pulls down the other client's `seqno=2` value.
                
                // Feed the new config into each other.  (This array could hold multiple configs if we pulled
                // down more than one).
                var mergeHashes2: [UnsafePointer<CChar>?] = [cFakeHash2].unsafeCopy()
                var mergeData2: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData3.pointee.config)]
                var mergeSize2: [Int] = [pushData3.pointee.config_len]
                expect(config_merge(conf2, &mergeHashes2, &mergeData2, &mergeSize2, 1)).to(equal(1))
                pushData3.deallocate()
                var mergeHashes3: [UnsafePointer<CChar>?] = [cFakeHash3].unsafeCopy()
                var mergeData3: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData4.pointee.config)]
                var mergeSize3: [Int] = [pushData4.pointee.config_len]
                expect(config_merge(conf, &mergeHashes3, &mergeData3, &mergeSize3, 1)).to(equal(1))
                pushData4.deallocate()
                
                // Now after the merge we *will* want to push from both client, since both will have generated a
                // merge conflict update (with seqno = 3).
                expect(config_needs_push(conf)).to(beTrue())
                expect(config_needs_push(conf2)).to(beTrue())
                let pushData5: UnsafeMutablePointer<config_push_data> = config_push(conf)
                let pushData6: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData5.pointee.seqno).to(equal(3))
                expect(pushData6.pointee.seqno).to(equal(3))
                
                // They should have resolved the conflict to the same thing:
                expect(String(cString: user_profile_get_name(conf)!)).to(equal("Nibbler"))
                expect(String(cString: user_profile_get_name(conf2)!)).to(equal("Nibbler"))
                // (Note that they could have also both resolved to "Raz" here, but the hash of the serialized
                // message just happens to have a higher hash -- and thus gets priority -- for this particular
                // test).
                
                // Since only one of them set a profile pic there should be no conflict there:
                let pic3: user_profile_pic = user_profile_get_pic(conf)
                expect(pic3.url).toNot(beNil())
                expect(String(libSessionVal: pic3.url)).to(equal("http://new.example.com/pic"))
                expect(pic3.key).toNot(beNil())
                expect(Data(libSessionVal: pic3.key, count: 32).toHexString())
                    .to(equal("7177657274007975696f31323334353637383930313233343536373839303132"))
                let pic4: user_profile_pic = user_profile_get_pic(conf2)
                expect(pic4.url).toNot(beNil())
                expect(String(libSessionVal: pic4.url)).to(equal("http://new.example.com/pic"))
                expect(pic4.key).toNot(beNil())
                expect(Data(libSessionVal: pic4.key, count: 32).toHexString())
                    .to(equal("7177657274007975696f31323334353637383930313233343536373839303132"))
                expect(user_profile_get_nts_priority(conf)).to(equal(9))
                expect(user_profile_get_nts_priority(conf2)).to(equal(9))
                
                let fakeHash4: String = "fakehash4"
                var cFakeHash4: [CChar] = fakeHash4.cArray.nullTerminated()
                let fakeHash5: String = "fakehash5"
                var cFakeHash5: [CChar] = fakeHash5.cArray.nullTerminated()
                config_confirm_pushed(conf, pushData5.pointee.seqno, &cFakeHash4)
                config_confirm_pushed(conf2, pushData6.pointee.seqno, &cFakeHash5)
                pushData5.deallocate()
                pushData6.deallocate()
                
                var dump6: UnsafeMutablePointer<UInt8>? = nil
                var dump6Len: Int = 0
                config_dump(conf, &dump6, &dump6Len);
                var dump7: UnsafeMutablePointer<UInt8>? = nil
                var dump7Len: Int = 0
                config_dump(conf2, &dump7, &dump7Len);
                // (store in db)
                dump6?.deallocate()
                dump7?.deallocate()
                
                expect(config_needs_dump(conf)).to(beFalse())
                expect(config_needs_dump(conf2)).to(beFalse())
                expect(config_needs_push(conf)).to(beFalse())
                expect(config_needs_push(conf2)).to(beFalse())
                
                // Wouldn't do this in a normal session but doing it here to properly clean up
                // after the test
                conf?.deallocate()
                conf2?.deallocate()
            }
        }
    }
}
