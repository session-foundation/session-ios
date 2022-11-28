// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtil

import Quick
import Nimble

/// This spec is designed to replicate the initial test cases for the libSession-util to ensure the behaviour matches
class ConfigUserProfileSpec: QuickSpec {
    // MARK: - Spec

    override func spec() {
        it("behaves correctly") {
            // Initialize a brand new, empty config because we have no dump data to deal with.
            let error: UnsafeMutablePointer<CChar>? = nil
            var conf: UnsafeMutablePointer<config_object>? = nil
            expect(user_profile_init(&conf, nil, 0, error)).to(equal(0))
            
            // We don't need to push anything, since this is an empty config
            expect(config_needs_push(conf)).to(beFalse())
            // And we haven't changed anything so don't need to dump to db
            expect(config_needs_dump(conf)).to(beFalse())
            
            // Since it's empty there shouldn't be a name.
            let namePtr = user_profile_get_name(conf)
            expect(namePtr).to(beNil())
            
            var toPush: UnsafeMutablePointer<CChar>? = nil
            var toPushLen: Int = 0
            // We don't need to push since we haven't changed anything, so this call is mainly just for
            // testing:
            let seqno: Int64 = config_push(conf, &toPush, &toPushLen)
            expect(toPush).toNot(beNil())
            expect(seqno).to(equal(0))
            expect(String(cString: toPush!)).to(equal("d1:#i0e1:&de1:<le1:=dee"))
            
            // This should also be unset:
            let pic = user_profile_get_pic(conf)
            expect(pic.url).to(beNil())
            expect(pic.key).to(beNil())
            expect(pic.keylen).to(equal(0))

            
            // Now let's go set a profile name and picture:
            expect(user_profile_set_name(conf, "Kallie")).to(equal(0))
            let profileUrl: [CChar] = "http://example.org/omg-pic-123.bmp"
                .bytes
                .map { CChar(bitPattern: $0) }
            let profileKey: [CChar] = "secretNOTSECRET"
                .bytes
                .map { CChar(bitPattern: $0) }
            let p: user_profile_pic = profileUrl.withUnsafeBufferPointer { profileUrlPtr in
                profileKey.withUnsafeBufferPointer { profileKeyPtr in
                    user_profile_pic(
                        url: profileUrlPtr.baseAddress,
                        key: profileKeyPtr.baseAddress,
                        keylen: 6
                    )
                }
            }
            expect(user_profile_set_pic(conf, p)).to(equal(0))
            
            // Retrieve them just to make sure they set properly:
            let namePtr2 = user_profile_get_name(conf)
            expect(namePtr2).toNot(beNil())
            expect(String(cString: namePtr2!)).to(equal("Kallie"))
            
            let pic2 = user_profile_get_pic(conf);
            expect(pic2.url).toNot(beNil())
            expect(pic2.key).toNot(beNil())
            expect(pic2.keylen).to(equal(6))
            expect(String(cString: pic2.url!)).to(equal("http://example.org/omg-pic-123.bmp"))
            expect(String(cString: pic2.key!)).to(equal("secret"))
            
            // Since we've made changes, we should need to push new config to the swarm, *and* should need
            // to dump the updated state:
            expect(config_needs_push(conf)).to(beTrue())
            expect(config_needs_dump(conf)).to(beTrue())
            
            var toPush2: UnsafeMutablePointer<CChar>? = nil
            var toPush2Len: Int = 0
            let seqno2 = config_push(conf, &toPush2, &toPush2Len);
            // incremented since we made changes (this only increments once between
            // dumps; even though we changed two fields here).
            expect(seqno2).to(equal(1))
            
            // Note: This hex value differs from the value in the library tests because
            // it looks like the library has an "end of cell mark" character added at the
            // end (0x07 or '0007') so we need to manually add it to work
            let expHash0: [CChar] = Data(hex: "ea173b57beca8af18c3519a7bbf69c3e7a05d1c049fa9558341d8ebb48b0c965")
                .bytes
                .map { CChar(bitPattern: $0) }
//                .withUnsafeBufferPointer { profileKeyPtr in
//                    String(cString: profileKeyPtr.baseAddress!)
//                }
            // The data to be actually pushed, expanded like this to make it somewhat human-readable:
            let expPush1: [CChar] = ["""
                d
                  1:#i1e
                  1:& d
                    1:n 6:Kallie
                    1:p 34:http://example.org/omg-pic-123.bmp
                    1:q 6:secret
                  e
                  1:< l
                    l i0e 32:
            """.removeCharacters(characterSet: CharacterSet.whitespacesAndNewlines) // For readability
                .bytes
                .map { CChar(bitPattern: $0) },
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
                .map { CChar(bitPattern: $0) },
//             [CChar()] // Need to null-terminate the string or it'll crash
            ]
            .flatMap { $0 }
            
            expect(String(cString: toPush2!))
                // Need to null-terminate the string or it'll crash
                .to(equal(String(cString: expPush1.appending(CChar()))))
            
            // We haven't dumped, so still need to dump:
            expect(config_needs_dump(conf)).to(beTrue())
            // We did call push, but we haven't confirmed it as stored yet, so this will still return true:
            expect(config_needs_push(conf)).to(beTrue())
            
            var dump1: UnsafeMutablePointer<CChar>? = nil
            var dump1Len: Int = 0
            
            config_dump(conf, &dump1, &dump1Len)
            // (in a real client we'd now store this to disk)
            
            expect(config_needs_dump(conf)).to(beFalse())
            
            let expDump1: [CChar] = [
                """
                    d
                      1:! i2e
                      1:$ \(expPush1.count):
                """
                    .removeCharacters(characterSet: CharacterSet.whitespacesAndNewlines)
                    .bytes
                    .map { CChar(bitPattern: $0) },
                expPush1,
                """
                    e
                """.removeCharacters(characterSet: CharacterSet.whitespacesAndNewlines)
                    .bytes
                    .map { CChar(bitPattern: $0) }
            ]
            .flatMap { $0 }
            expect(String(cString: dump1!))
                .to(equal(String(cString: expDump1.appending(CChar()))))// Need to null-terminate the string or it'll crash
            
            // So now imagine we got back confirmation from the swarm that the push has been stored:
            config_confirm_pushed(conf, seqno2)
            
            expect(config_needs_push(conf)).to(beFalse())
            expect(config_needs_dump(conf)).to(beTrue()) // The confirmation changes state, so this makes us need a dump
            
            var dump2: UnsafeMutablePointer<CChar>? = nil
            var dump2Len: Int = 0
            config_dump(conf, &dump2, &dump2Len)
  
            expect(config_needs_dump(conf)).to(beFalse())
            
            // Now we're going to set up a second, competing config object (in the real world this would be
            // another Session client somewhere).

            // Start with an empty config, as above:
            let error2: UnsafeMutablePointer<CChar>? = nil
            var conf2: UnsafeMutablePointer<config_object>? = nil
            expect(user_profile_init(&conf2, nil, 0, error2)).to(equal(0))
            expect(config_needs_dump(conf2)).to(beFalse())
            
            // Now imagine we just pulled down the `exp_push1` string from the swarm; we merge it into
            // conf2:
            let mergeData: [[CChar]] = [expPush1]
            var mergeDataPtr = mergeData.map { value in
                let cStringCopy = UnsafeMutableBufferPointer<CChar>.allocate(capacity: value.count)
                _ = cStringCopy.initialize(from: value)
                let ptr = UnsafePointer(cStringCopy.baseAddress)
                return UnsafePointer(cStringCopy.baseAddress)
            }
            var mergeSize: [Int] = [expPush1.count]
            config_merge(conf2, &mergeDataPtr, &mergeSize, 1)

            // Our state has changed, so we need to dump:
            expect(config_needs_dump(conf2)).to(beTrue())
            var dump3: UnsafeMutablePointer<CChar>? = nil
            var dump3Len: Int = 0
            config_dump(conf, &dump3, &dump3Len)
            // (store in db)
            expect(config_needs_dump(conf2)).to(beFalse())// TODO: This one is broken now!!!
            
            // We *don't* need to push: even though we updated, all we did is update to the merged data (and
            // didn't have any sort of merge conflict needed):
            expect(config_needs_push(conf2)).to(beFalse())

            // Now let's create a conflicting update:

            // Change the name on both clients:
            user_profile_set_name(conf, "Nibbler")
            user_profile_set_name(conf2, "Raz")
            
            // And, on conf2, we're also going to change the profile pic:
            let profile2Url: [CChar] = "http://new.example.com/pic"
                .bytes
                .map { CChar(bitPattern: $0) }
            let profile2Key: [CChar] = "qwert\0yuio"
                .bytes
                .map { CChar(bitPattern: $0) }
            let p2: user_profile_pic = profile2Url.withUnsafeBufferPointer { profile2UrlPtr in
                profile2Key.withUnsafeBufferPointer { profile2KeyPtr in
                    user_profile_pic(
                        url: profile2UrlPtr.baseAddress,
                        key: profile2KeyPtr.baseAddress,
                        keylen: 10
                    )
                }
            }
            user_profile_set_pic(conf2, p2)
            
            // Both have changes, so push need a push
            expect(config_needs_push(conf)).to(beTrue())
            expect(config_needs_push(conf2)).to(beTrue())
            var toPush3: UnsafeMutablePointer<CChar>? = nil
            var toPush3Len: Int = 0
            let seqno3 = config_push(conf, &toPush3, &toPush3Len)
            expect(seqno3).to(equal(2)) // incremented, since we made a field change
            
            var toPush4: UnsafeMutablePointer<CChar>? = nil
            var toPush4Len: Int = 0
            let seqno4 = config_push(conf2, &toPush4, &toPush4Len)
            expect(seqno4).to(equal(2)) // incremented, since we made a field change

            var dump4: UnsafeMutablePointer<CChar>? = nil
            var dump4Len: Int = 0
            config_dump(conf, &dump4, &dump4Len);
            var dump5: UnsafeMutablePointer<CChar>? = nil
            var dump5Len: Int = 0
            config_dump(conf2, &dump5, &dump5Len);
            // (store in db)
            
            // Since we set different things, we're going to get back different serialized data to be
            // pushed:
            expect(String(cString: toPush3!)).toNot(equal(String(cString: toPush4!)))
            
            // Now imagine that each client pushed its `seqno=2` config to the swarm, but then each client
            // also fetches new messages and pulls down the other client's `seqno=2` value.

            // Feed the new config into each other.  (This array could hold multiple configs if we pulled
            // down more than one).
            let mergeData2: [String] = [String(cString: toPush3!)]
            var mergeData2Ptr = mergeData2.map { value in
                value.bytes.map { CChar(bitPattern: $0) }.withUnsafeBufferPointer { valuePtr in
                    valuePtr.baseAddress
                }
            }
            var mergeSize2: [Int] = [toPush3Len]
            config_merge(conf2, &mergeData2Ptr, &mergeSize2, 1)
            let mergeData3: [String] = [String(cString: toPush4!)]
            var mergeData3Ptr = mergeData3.map { value in
                value.bytes.map { CChar(bitPattern: $0) }.withUnsafeBufferPointer { valuePtr in
                    valuePtr.baseAddress
                }
            }
            var mergeSize3: [Int] = [toPush4Len]
            config_merge(conf, &mergeData3Ptr, &mergeSize3, 1)
            
            // Now after the merge we *will* want to push from both client, since both will have generated a
            // merge conflict update (with seqno = 3).
            expect(config_needs_push(conf)).to(beTrue())
            expect(config_needs_push(conf2)).to(beTrue())
            let seqno5 = config_push(conf, &toPush3, &toPush3Len);
            let seqno6 = config_push(conf2, &toPush4, &toPush4Len);

            expect(seqno5).to(equal(3))
            expect(seqno6).to(equal(3))
            
            // They should have resolved the conflict to the same thing:
            expect(String(cString: user_profile_get_name(conf)!)).to(equal("Nibbler"))
            expect(String(cString: user_profile_get_name(conf2)!)).to(equal("Nibbler"))
            // (Note that they could have also both resolved to "Raz" here, but the hash of the serialized
            // message just happens to have a higher hash -- and thus gets priority -- for this particular
            // test).

            // Since only one of them set a profile pic there should be no conflict there:
            let pic3 = user_profile_get_pic(conf)
            expect(pic3.url).toNot(beNil())
            expect(String(cString: pic3.url!)).to(equal("http://new.example.com/pic"))
            expect(pic3.key).toNot(beNil())
            expect(String(cString: pic3.key!)).to(equal("qwert\0yuio"))
            let pic4 = user_profile_get_pic(conf2)
            expect(pic4.url).toNot(beNil())
            expect(String(cString: pic4.url!)).to(equal("http://new.example.com/pic"))
            expect(pic4.key).toNot(beNil())
            expect(String(cString: pic4.key!)).to(equal("qwert\0yuio"))

            config_confirm_pushed(conf, seqno5)
            config_confirm_pushed(conf2, seqno6)
            
            var dump6: UnsafeMutablePointer<CChar>? = nil
            var dump6Len: Int = 0
            config_dump(conf, &dump6, &dump6Len);
            var dump7: UnsafeMutablePointer<CChar>? = nil
            var dump7Len: Int = 0
            config_dump(conf2, &dump7, &dump7Len);
            // (store in db)

            expect(config_needs_dump(conf)).to(beFalse())
            expect(config_needs_dump(conf2)).to(beFalse())
            expect(config_needs_push(conf)).to(beFalse())
            expect(config_needs_push(conf2)).to(beFalse())
        }
    }
}
