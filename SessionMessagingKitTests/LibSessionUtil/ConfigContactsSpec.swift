// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Sodium
import SessionUtil
import SessionUtilitiesKit

import Quick
import Nimble

/// This spec is designed to replicate the initial test cases for the libSession-util to ensure the behaviour matches
class ConfigContactsSpec: QuickSpec {
    // MARK: - Spec

    override func spec() {
        it("generates Contact configs correctly") {
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
            expect(contacts_init(&conf, &edSK, nil, 0, error)).to(equal(0))
            error?.deallocate()
            
            // Empty contacts shouldn't have an existing contact
            var definitelyRealId: String = "050000000000000000000000000000000000000000000000000000000000000000"
            var cDefinitelyRealId: [CChar] = definitelyRealId.cArray
            let contactPtr: UnsafeMutablePointer<contacts_contact>? = nil
            expect(contacts_get(conf, contactPtr, &cDefinitelyRealId)).to(beFalse())
            
            expect(contacts_size(conf)).to(equal(0))
            
            var contact2: contacts_contact = contacts_contact()
            expect(contacts_get_or_construct(conf, &contact2, &cDefinitelyRealId)).to(beTrue())
            expect(String(libSessionVal: contact2.name)).to(beEmpty())
            expect(String(libSessionVal: contact2.nickname)).to(beEmpty())
            expect(contact2.approved).to(beFalse())
            expect(contact2.approved_me).to(beFalse())
            expect(contact2.blocked).to(beFalse())
            expect(contact2.profile_pic).toNot(beNil()) // Creates an empty instance apparently
            expect(String(libSessionVal: contact2.profile_pic.url)).to(beEmpty())

            // We don't need to push anything, since this is a default contact
            expect(config_needs_push(conf)).to(beFalse())
            // And we haven't changed anything so don't need to dump to db
            expect(config_needs_dump(conf)).to(beFalse())
            
            var toPush: UnsafeMutablePointer<UInt8>? = nil
            var toPushLen: Int = 0
            // We don't need to push since we haven't changed anything, so this call is mainly just for
            // testing:
            let seqno: Int64 = config_push(conf, &toPush, &toPushLen)
            expect(toPush).toNot(beNil())
            expect(seqno).to(equal(0))
            expect(toPushLen).to(equal(256))
            toPush?.deallocate()
            
            // Update the contact data
            contact2.name = "Joe".toLibSession()
            contact2.nickname = "Joey".toLibSession()
            contact2.approved = true
            contact2.approved_me = true
            
            // Update the contact
            contacts_set(conf, &contact2)
            
            // Ensure the contact details were updated
            var contact3: contacts_contact = contacts_contact()
            expect(contacts_get(conf, &contact3, &definitelyRealId)).to(beTrue())
            expect(String(libSessionVal: contact3.name)).to(equal("Joe"))
            expect(String(libSessionVal: contact3.nickname)).to(equal("Joey"))
            expect(contact3.approved).to(beTrue())
            expect(contact3.approved_me).to(beTrue())
            expect(contact3.profile_pic).toNot(beNil()) // Creates an empty instance apparently
            expect(String(libSessionVal: contact3.profile_pic.url)).to(beEmpty())
            expect(contact3.blocked).to(beFalse())
            expect(String(libSessionVal: contact3.session_id)).to(equal(definitelyRealId))
            
            // Since we've made changes, we should need to push new config to the swarm, *and* should need
            // to dump the updated state:
            expect(config_needs_push(conf)).to(beTrue())
            expect(config_needs_dump(conf)).to(beTrue())
            
            var toPush2: UnsafeMutablePointer<UInt8>? = nil
            var toPush2Len: Int = 0
            let seqno2: Int64 = config_push(conf, &toPush2, &toPush2Len);
            // incremented since we made changes (this only increments once between
            // dumps; even though we changed multiple fields here).
            expect(seqno2).to(equal(1))
            toPush2?.deallocate()
            
            // Pretend we uploaded it
            config_confirm_pushed(conf, seqno2)
            expect(config_needs_push(conf)).to(beFalse())
            expect(config_needs_dump(conf)).to(beTrue())
            
            // NB: Not going to check encrypted data and decryption here because that's general (not
            // specific to contacts) and is covered already in the user profile tests.
            var dump1: UnsafeMutablePointer<UInt8>? = nil
            var dump1Len: Int = 0
            config_dump(conf, &dump1, &dump1Len)
            
            let error2: UnsafeMutablePointer<CChar>? = nil
            var conf2: UnsafeMutablePointer<config_object>? = nil
            expect(contacts_init(&conf2, &edSK, dump1, dump1Len, error2)).to(equal(0))
            error2?.deallocate()
            dump1?.deallocate()
            
            expect(config_needs_push(conf2)).to(beFalse())
            expect(config_needs_dump(conf2)).to(beFalse())
            
            var toPush3: UnsafeMutablePointer<UInt8>? = nil
            var toPush3Len: Int = 0
            let seqno3: Int64 = config_push(conf, &toPush3, &toPush3Len);
            expect(seqno3).to(equal(1))
            toPush3?.deallocate()
            
            // Because we just called dump() above, to load up contacts2
            expect(config_needs_dump(conf)).to(beFalse())
            
            // Ensure the contact details were updated
            var contact4: contacts_contact = contacts_contact()
            expect(contacts_get(conf2, &contact4, &definitelyRealId)).to(beTrue())
            expect(String(libSessionVal: contact4.name)).to(equal("Joe"))
            expect(String(libSessionVal: contact4.nickname)).to(equal("Joey"))
            expect(contact4.approved).to(beTrue())
            expect(contact4.approved_me).to(beTrue())
            expect(contact4.profile_pic).toNot(beNil()) // Creates an empty instance apparently
            expect(String(libSessionVal: contact4.profile_pic.url)).to(beEmpty())
            expect(contact4.blocked).to(beFalse())
            
            var anotherId: String = "051111111111111111111111111111111111111111111111111111111111111111"
            var cAnotherId: [CChar] = anotherId.cArray
            var contact5: contacts_contact = contacts_contact()
            expect(contacts_get_or_construct(conf2, &contact5, &cAnotherId)).to(beTrue())
            expect(String(libSessionVal: contact5.name)).to(beEmpty())
            expect(String(libSessionVal: contact5.nickname)).to(beEmpty())
            expect(contact5.approved).to(beFalse())
            expect(contact5.approved_me).to(beFalse())
            expect(contact5.profile_pic).toNot(beNil()) // Creates an empty instance apparently
            expect(String(libSessionVal: contact5.profile_pic.url)).to(beEmpty())
            expect(contact5.blocked).to(beFalse())
            
            // We're not setting any fields, but we should still keep a record of the session id
            contacts_set(conf2, &contact5)
            expect(config_needs_push(conf2)).to(beTrue())
            
            var toPush4: UnsafeMutablePointer<UInt8>? = nil
            var toPush4Len: Int = 0
            let seqno4: Int64 = config_push(conf2, &toPush4, &toPush4Len);
            expect(seqno4).to(equal(2))
            
            // Check the merging
            var mergeData: [UnsafePointer<UInt8>?] = [UnsafePointer(toPush4)]
            var mergeSize: [Int] = [toPush4Len]
            expect(config_merge(conf, &mergeData, &mergeSize, 1)).to(equal(1))
            config_confirm_pushed(conf2, seqno4)
            toPush4?.deallocate()
            
            expect(config_needs_push(conf)).to(beFalse())
            
            var toPush5: UnsafeMutablePointer<UInt8>? = nil
            var toPush5Len: Int = 0
            let seqno5: Int64 = config_push(conf2, &toPush5, &toPush5Len);
            expect(seqno5).to(equal(2))
            toPush5?.deallocate()

            // Iterate through and make sure we got everything we expected
            var sessionIds: [String] = []
            var nicknames: [String] = []
            expect(contacts_size(conf)).to(equal(2))
            
            var contact6: contacts_contact = contacts_contact()
            let contactIterator: UnsafeMutablePointer<contacts_iterator> = contacts_iterator_new(conf)
            while !contacts_iterator_done(contactIterator, &contact6) {
                sessionIds.append(String(libSessionVal: contact6.session_id) ?? "(N/A)")
                nicknames.append(String(libSessionVal: contact6.nickname, nullIfEmpty: true) ?? "(N/A)")
                contacts_iterator_advance(contactIterator)
            }
            contacts_iterator_free(contactIterator) // Need to free the iterator
            
            expect(sessionIds.count).to(equal(2))
            expect(sessionIds.count).to(equal(contacts_size(conf)))
            expect(sessionIds.first).to(equal(definitelyRealId))
            expect(sessionIds.last).to(equal(anotherId))
            expect(nicknames.first).to(equal("Joey"))
            expect(nicknames.last).to(equal("(N/A)"))

            // Conflict! Oh no!

            // On client 1 delete a contact:
            contacts_erase(conf, definitelyRealId)
            
            // Client 2 adds a new friend:
            var thirdId: String = "052222222222222222222222222222222222222222222222222222222222222222"
            var cThirdId: [CChar] = thirdId.cArray
            var contact7: contacts_contact = contacts_contact()
            expect(contacts_get_or_construct(conf2, &contact7, &cThirdId)).to(beTrue())
            contact7.nickname = "Nickname 3".toLibSession()
            contact7.approved = true
            contact7.approved_me = true
            contact7.profile_pic.url = "http://example.com/huge.bmp".toLibSession()
            contact7.profile_pic.key = "qwerty78901234567890123456789012".data(using: .utf8)!.toLibSession()
            contacts_set(conf2, &contact7)
            
            expect(config_needs_push(conf)).to(beTrue())
            expect(config_needs_push(conf2)).to(beTrue())
            
            var toPush6: UnsafeMutablePointer<UInt8>? = nil
            var toPush6Len: Int = 0
            let seqno6: Int64 = config_push(conf, &toPush6, &toPush6Len);
            expect(seqno6).to(equal(3))
            
            var toPush7: UnsafeMutablePointer<UInt8>? = nil
            var toPush7Len: Int = 0
            let seqno7: Int64 = config_push(conf2, &toPush7, &toPush7Len);
            expect(seqno7).to(equal(3))

            expect(String(pointer: toPush6, length: toPush6Len, encoding: .ascii))
                .toNot(equal(String(pointer: toPush7, length: toPush7Len, encoding: .ascii)))
            
            config_confirm_pushed(conf, seqno6)
            config_confirm_pushed(conf2, seqno7)
            
            var mergeData2: [UnsafePointer<UInt8>?] = [UnsafePointer(toPush7)]
            var mergeSize2: [Int] = [toPush7Len]
            expect(config_merge(conf, &mergeData2, &mergeSize2, 1)).to(equal(1))
            expect(config_needs_push(conf)).to(beTrue())
            
            var mergeData3: [UnsafePointer<UInt8>?] = [UnsafePointer(toPush6)]
            var mergeSize3: [Int] = [toPush6Len]
            expect(config_merge(conf2, &mergeData3, &mergeSize3, 1)).to(equal(1))
            expect(config_needs_push(conf2)).to(beTrue())
            toPush6?.deallocate()
            toPush7?.deallocate()
            
            var toPush8: UnsafeMutablePointer<UInt8>? = nil
            var toPush8Len: Int = 0
            let seqno8: Int64 = config_push(conf, &toPush8, &toPush8Len);
            expect(seqno8).to(equal(4))
            
            var toPush9: UnsafeMutablePointer<UInt8>? = nil
            var toPush9Len: Int = 0
            let seqno9: Int64 = config_push(conf2, &toPush9, &toPush9Len);
            expect(seqno9).to(equal(seqno8))
            
            expect(String(pointer: toPush8, length: toPush8Len, encoding: .ascii))
                .to(equal(String(pointer: toPush9, length: toPush9Len, encoding: .ascii)))
            toPush8?.deallocate()
            toPush9?.deallocate()
            
            config_confirm_pushed(conf, seqno8)
            config_confirm_pushed(conf2, seqno9)
            
            expect(config_needs_push(conf)).to(beFalse())
            expect(config_needs_push(conf2)).to(beFalse())
            
            // Validate the changes
            var sessionIds2: [String] = []
            var nicknames2: [String] = []
            expect(contacts_size(conf)).to(equal(2))
                                        
            var contact8: contacts_contact = contacts_contact()
            let contactIterator2: UnsafeMutablePointer<contacts_iterator> = contacts_iterator_new(conf)
            while !contacts_iterator_done(contactIterator2, &contact8) {
                sessionIds2.append(String(libSessionVal: contact8.session_id) ?? "(N/A)")
                nicknames2.append(String(libSessionVal: contact8.nickname, nullIfEmpty: true) ?? "(N/A)")
                contacts_iterator_advance(contactIterator2)
            }
            contacts_iterator_free(contactIterator2) // Need to free the iterator
            
            expect(sessionIds2.count).to(equal(2))
            expect(sessionIds2.first).to(equal(anotherId))
            expect(sessionIds2.last).to(equal(thirdId))
            expect(nicknames2.first).to(equal("(N/A)"))
            expect(nicknames2.last).to(equal("Nickname 3"))
        }
    }
}
