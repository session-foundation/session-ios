// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import SessionUtil
import SessionUtilitiesKit
import SessionMessagingKit

import Quick
import Nimble

/// This spec is designed to replicate the initial test cases for the libSession-util to ensure the behaviour matches
class ConfigUserProfileSpec: QuickSpec {
    // MARK: - Spec

    override func spec() {
        it("generates UserProfile configs correctly") {
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
            
            var toPush: UnsafeMutablePointer<UInt8>? = nil
            var toPushLen: Int = 0
            // We don't need to push since we haven't changed anything, so this call is mainly just for
            // testing:
            let seqno: Int64 = config_push(conf, &toPush, &toPushLen)
            expect(toPush).toNot(beNil())
            expect(seqno).to(equal(0))
            expect(toPushLen).to(equal(256))
            
            let encDomain: [CChar] = "UserProfile"
                .bytes
                .map { CChar(bitPattern: $0) }
            expect(String(cString: config_encryption_domain(conf))).to(equal("UserProfile"))
            
            var toPushDecSize: Int = 0
            let toPushDecrypted: UnsafeMutablePointer<UInt8>? = config_decrypt(toPush, toPushLen, edSK, encDomain, &toPushDecSize)
            let prefixPadding: String = (0..<193)
                .map { _ in "\0" }
                .joined()
            expect(toPushDecrypted).toNot(beNil())
            expect(toPushDecSize).to(equal(216))  // 256 - 40 overhead
            expect(String(pointer: toPushDecrypted, length: toPushDecSize))
                .to(equal("\(prefixPadding)d1:#i0e1:&de1:<le1:=dee"))
            toPush?.deallocate()
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
            
            // Retrieve them just to make sure they set properly:
            let namePtr2: UnsafePointer<CChar>? = user_profile_get_name(conf)
            expect(namePtr2).toNot(beNil())
            expect(String(cString: namePtr2!)).to(equal("Kallie"))
            
            let pic2: user_profile_pic = user_profile_get_pic(conf);
            expect(String(libSessionVal: pic2.url)).to(equal("http://example.org/omg-pic-123.bmp"))
            expect(Data(libSessionVal: pic2.key, count: ProfileManager.avatarAES256KeyByteLength))
                .to(equal("secret78901234567890123456789012".data(using: .utf8)))
            
            // Since we've made changes, we should need to push new config to the swarm, *and* should need
            // to dump the updated state:
            expect(config_needs_push(conf)).to(beTrue())
            expect(config_needs_dump(conf)).to(beTrue())
            
            var toPush2: UnsafeMutablePointer<UInt8>? = nil
            var toPush2Len: Int = 0
            let seqno2: Int64 = config_push(conf, &toPush2, &toPush2Len);
            // incremented since we made changes (this only increments once between
            // dumps; even though we changed two fields here).
            expect(seqno2).to(equal(1))
            
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
                    1:n 0:
                    1:p 0:
                    1:q 0:
                  e
                e
            """.removeCharacters(characterSet: CharacterSet.whitespacesAndNewlines) // For readability
                .bytes
            ]
            .flatMap { $0 }
            let expPush1Encrypted: [UInt8] = Data(hex: [
              "877c8e0f5d33f5fffa5a4e162785a9a89918e95de1c4b925201f1f5c29d9ee4f8c36e2b278fce1e6",
              "b9d999689dd86ff8e79e0a04004fa54d24da89bc2604cb1df8c1356da8f14710543ecec44f2d57fc",
              "56ea8b7e73d119c69d755f4d513d5d069f02396b8ec0cbed894169836f57ca4b782ce705895c593b",
              "4230d50c175d44a08045388d3f4160bacb617b9ae8de3ebc8d9024245cd09ce102627cab2acf1b91",
              "26159211359606611ca5814de320d1a7099a65c99b0eebbefb92a115f5efa6b9132809300ac010c6",
              "857cfbd62af71b0fa97eccec75cb95e67edf40b35fdb9cad125a6976693ab085c6bba96a2e51826e",
              "81e16b9ec1232af5680f2ced55310486"
            ].joined()).bytes
            
            expect(String(pointer: toPush2, length: toPush2Len, encoding: .ascii))
                .to(equal(String(pointer: expPush1Encrypted, length: expPush1Encrypted.count, encoding: .ascii)))
            
            // Raw decryption doesn't unpad (i.e. the padding is part of the encrypted data)
            var toPush2DecSize: Int = 0
            let toPush2Decrypted: UnsafeMutablePointer<UInt8>? = config_decrypt(
                toPush2,
                toPush2Len,
                edSK,
                encDomain,
                &toPush2DecSize
            )
            let prefixPadding2: String = (0..<(256 - 40 - expPush1Decrypted.count))
                .map { _ in "\0" }
                .joined()
            expect(toPush2DecSize).to(equal(216))  // 256 - 40 overhead
            expect(String(pointer: toPush2Decrypted, length: toPush2DecSize, encoding: .ascii))
                .to(equal(String(pointer: expPush1Decrypted, length: expPush1Decrypted.count, encoding: .ascii).map { "\(prefixPadding2)\($0)" }))
            toPush2?.deallocate()
            toPush2Decrypted?.deallocate()
            
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
                    e
                """.removeCharacters(characterSet: CharacterSet.whitespacesAndNewlines)
                    .bytes
                    .map { CChar(bitPattern: $0) }
            ]
            .flatMap { $0 }
            expect(String(pointer: dump1, length: dump1Len, encoding: .ascii))
                .to(equal(String(pointer: expDump1, length: expDump1.count, encoding: .ascii)))
            dump1?.deallocate()
            
            // So now imagine we got back confirmation from the swarm that the push has been stored:
            config_confirm_pushed(conf, seqno2)
            
            expect(config_needs_push(conf)).to(beFalse())
            expect(config_needs_dump(conf)).to(beTrue()) // The confirmation changes state, so this makes us need a dump
            
            var dump2: UnsafeMutablePointer<UInt8>? = nil
            var dump2Len: Int = 0
            config_dump(conf, &dump2, &dump2Len)
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
            var mergeData: [UnsafePointer<UInt8>?] = [expPush1Encrypted].unsafeCopy()
            var mergeSize: [Int] = [expPush1Encrypted.count]
            expect(config_merge(conf2, &mergeData, &mergeSize, 1)).to(equal(1))
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
            var toPush3: UnsafeMutablePointer<UInt8>? = nil
            var toPush3Len: Int = 0
            let seqno3: Int64 = config_push(conf, &toPush3, &toPush3Len)
            expect(seqno3).to(equal(2)) // incremented, since we made a field change
            
            var toPush4: UnsafeMutablePointer<UInt8>? = nil
            var toPush4Len: Int = 0
            let seqno4: Int64 = config_push(conf2, &toPush4, &toPush4Len)
            expect(seqno4).to(equal(2)) // incremented, since we made a field change

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
            expect(String(pointer: toPush3, length: toPush3Len, encoding: .ascii))
                .toNot(equal(String(pointer: toPush4, length: toPush4Len, encoding: .ascii)))
            
            // Now imagine that each client pushed its `seqno=2` config to the swarm, but then each client
            // also fetches new messages and pulls down the other client's `seqno=2` value.

            // Feed the new config into each other.  (This array could hold multiple configs if we pulled
            // down more than one).
            var mergeData2: [UnsafePointer<UInt8>?] = [UnsafePointer(toPush3)]
            var mergeSize2: [Int] = [toPush3Len]
            expect(config_merge(conf2, &mergeData2, &mergeSize2, 1)).to(equal(1))
            toPush3?.deallocate()
            var mergeData3: [UnsafePointer<UInt8>?] = [UnsafePointer(toPush4)]
            var mergeSize3: [Int] = [toPush4Len]
            expect(config_merge(conf, &mergeData3, &mergeSize3, 1)).to(equal(1))
            toPush4?.deallocate()
            
            // Now after the merge we *will* want to push from both client, since both will have generated a
            // merge conflict update (with seqno = 3).
            expect(config_needs_push(conf)).to(beTrue())
            expect(config_needs_push(conf2)).to(beTrue())
            let seqno5: Int64 = config_push(conf, &toPush3, &toPush3Len);
            let seqno6: Int64 = config_push(conf2, &toPush4, &toPush4Len);

            expect(seqno5).to(equal(3))
            expect(seqno6).to(equal(3))
            
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

            config_confirm_pushed(conf, seqno5)
            config_confirm_pushed(conf2, seqno6)
            
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
