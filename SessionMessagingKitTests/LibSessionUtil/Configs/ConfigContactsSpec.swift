// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import Sodium
import SessionUtil
import SessionUtilitiesKit

import Quick
import Nimble

@testable import SessionMessagingKit

/// This spec is designed to replicate the initial test cases for the libSession-util to ensure the behaviour matches
class ConfigContactsSpec {
    enum ContactProperty: CaseIterable {
        case name
        case nickname
        case approved
        case approved_me
        case blocked
        case profile_pic
        case created
        case notifications
        case mute_until
    }
    
    // MARK: - Spec

    static func spec() {
        context("CONTACTS") {
            // MARK: - when checking error catching
            context("when checking error catching") {
                var seed: Data!
                var identity: (ed25519KeyPair: KeyPair, x25519KeyPair: KeyPair)!
                var edSK: [UInt8]!
                var error: UnsafeMutablePointer<CChar>?
                var conf: UnsafeMutablePointer<config_object>?
                
                beforeEach {
                    seed = Data(hex: "0123456789abcdef0123456789abcdef")
                    
                    // FIXME: Would be good to move these into the libSession-util instead of using Sodium separately
                    identity = try! Identity.generate(from: seed)
                    edSK = identity.ed25519KeyPair.secretKey
                    
                    // Initialize a brand new, empty config because we have no dump data to deal with.
                    error = nil
                    conf = nil
                    _ = contacts_init(&conf, &edSK, nil, 0, error)
                    error?.deallocate()
                }
                
                // MARK: -- it can catch size limit errors thrown when pushing
                it("can catch size limit errors thrown when pushing") {
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)
                    
                    try (0..<10000).forEach { index in
                        var contact: contacts_contact = try createContact(
                            for: index,
                            in: conf,
                            rand: &randomGenerator,
                            maxing: .allProperties
                        )
                        contacts_set(conf, &contact)
                    }
                    
                    expect(contacts_size(conf)).to(equal(10000))
                    expect(config_needs_push(conf)).to(beTrue())
                    expect(config_needs_dump(conf)).to(beTrue())
                    
                    expect {
                        try CExceptionHelper.performSafely { config_push(conf).deallocate() }
                    }
                    .to(throwError(NSError(domain: "cpp_exception", code: -2, userInfo: ["NSLocalizedDescription": "Config data is too large"])))
                }
            }
            
            // MARK: - when checking size limits
            context("when checking size limits") {
                var numRecords: Int!
                var seed: Data!
                var identity: (ed25519KeyPair: KeyPair, x25519KeyPair: KeyPair)!
                var edSK: [UInt8]!
                var error: UnsafeMutablePointer<CChar>?
                var conf: UnsafeMutablePointer<config_object>?
                
                beforeEach {
                    numRecords = 0
                    seed = Data(hex: "0123456789abcdef0123456789abcdef")
                    
                    // FIXME: Would be good to move these into the libSession-util instead of using Sodium separately
                    identity = try! Identity.generate(from: seed)
                    edSK = identity.ed25519KeyPair.secretKey
                    
                    // Initialize a brand new, empty config because we have no dump data to deal with.
                    error = nil
                    conf = nil
                    _ = contacts_init(&conf, &edSK, nil, 0, error)
                    error?.deallocate()
                }
                
                // MARK: -- has not changed the max empty records
                it("has not changed the max empty records") {
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)
                    
                    for index in (0..<100000) {
                        var contact: contacts_contact = try createContact(
                            for: index,
                            in: conf,
                            rand: &randomGenerator
                        )
                        contacts_set(conf, &contact)
                        
                        do { try CExceptionHelper.performSafely { config_push(conf).deallocate() } }
                        catch { break }
                        
                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }
                    
                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(2370))
                }
                
                // MARK: -- has not changed the max name only records
                it("has not changed the max name only records") {
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)
                    
                    for index in (0..<100000) {
                        var contact: contacts_contact = try createContact(
                            for: index,
                            in: conf,
                            rand: &randomGenerator,
                            maxing: [.name]
                        )
                        contacts_set(conf, &contact)
                        
                        do { try CExceptionHelper.performSafely { config_push(conf).deallocate() } }
                        catch { break }
                        
                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }
                    
                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(796))
                }
                
                // MARK: -- has not changed the max name and profile pic only records
                it("has not changed the max name and profile pic only records") {
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)
                    
                    for index in (0..<100000) {
                        var contact: contacts_contact = try createContact(
                            for: index,
                            in: conf,
                            rand: &randomGenerator,
                            maxing: [.name, .profile_pic]
                        )
                        contacts_set(conf, &contact)
                        
                        do { try CExceptionHelper.performSafely { config_push(conf).deallocate() } }
                        catch { break }
                        
                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }
                    
                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(290))
                }
                
                // MARK: -- has not changed the max filled records
                it("has not changed the max filled records") {
                    var randomGenerator: ARC4RandomNumberGenerator = ARC4RandomNumberGenerator(seed: 1000)
                    
                    for index in (0..<100000) {
                        var contact: contacts_contact = try createContact(
                            for: index,
                            in: conf,
                            rand: &randomGenerator,
                            maxing: .allProperties
                        )
                        contacts_set(conf, &contact)
                        
                        do { try CExceptionHelper.performSafely { config_push(conf).deallocate() } }
                        catch { break }
                        
                        // We successfully inserted a contact and didn't hit the limit so increment the counter
                        numRecords += 1
                    }
                    
                    // Check that the record count matches the maximum when we last checked
                    expect(numRecords).to(equal(236))
                }
            }
            
            // MARK: - generates config correctly
            
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
                expect(contacts_init(&conf, &edSK, nil, 0, error)).to(equal(0))
                error?.deallocate()
                
                // Empty contacts shouldn't have an existing contact
                let definitelyRealId: String = "050000000000000000000000000000000000000000000000000000000000000000"
                var cDefinitelyRealId: [CChar] = definitelyRealId.cArray.nullTerminated()
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
                expect(contact2.created).to(equal(0))
                expect(contact2.notifications).to(equal(CONVO_NOTIFY_DEFAULT))
                expect(contact2.mute_until).to(equal(0))
                
                expect(config_needs_push(conf)).to(beFalse())
                expect(config_needs_dump(conf)).to(beFalse())
                
                let pushData1: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData1.pointee.seqno).to(equal(0))
                pushData1.deallocate()
                
                // Update the contact data
                contact2.name = "Joe".toLibSession()
                contact2.nickname = "Joey".toLibSession()
                contact2.approved = true
                contact2.approved_me = true
                contact2.created = createdTs
                contact2.notifications = CONVO_NOTIFY_ALL
                contact2.mute_until = nowTs + 1800
                
                // Update the contact
                contacts_set(conf, &contact2)
                
                // Ensure the contact details were updated
                var contact3: contacts_contact = contacts_contact()
                expect(contacts_get(conf, &contact3, &cDefinitelyRealId)).to(beTrue())
                expect(String(libSessionVal: contact3.name)).to(equal("Joe"))
                expect(String(libSessionVal: contact3.nickname)).to(equal("Joey"))
                expect(contact3.approved).to(beTrue())
                expect(contact3.approved_me).to(beTrue())
                expect(contact3.profile_pic).toNot(beNil()) // Creates an empty instance apparently
                expect(String(libSessionVal: contact3.profile_pic.url)).to(beEmpty())
                expect(contact3.blocked).to(beFalse())
                expect(String(libSessionVal: contact3.session_id)).to(equal(definitelyRealId))
                expect(contact3.created).to(equal(createdTs))
                expect(contact2.notifications).to(equal(CONVO_NOTIFY_ALL))
                expect(contact2.mute_until).to(equal(nowTs + 1800))
                
                
                // Since we've made changes, we should need to push new config to the swarm, *and* should need
                // to dump the updated state:
                expect(config_needs_push(conf)).to(beTrue())
                expect(config_needs_dump(conf)).to(beTrue())
                
                // incremented since we made changes (this only increments once between
                // dumps; even though we changed multiple fields here).
                let pushData2: UnsafeMutablePointer<config_push_data> = config_push(conf)
                
                // incremented since we made changes (this only increments once between
                // dumps; even though we changed multiple fields here).
                expect(pushData2.pointee.seqno).to(equal(1))
                
                // Pretend we uploaded it
                let fakeHash1: String = "fakehash1"
                var cFakeHash1: [CChar] = fakeHash1.cArray.nullTerminated()
                config_confirm_pushed(conf, pushData2.pointee.seqno, &cFakeHash1)
                expect(config_needs_push(conf)).to(beFalse())
                expect(config_needs_dump(conf)).to(beTrue())
                pushData2.deallocate()
                
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
                
                let pushData3: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData3.pointee.seqno).to(equal(1))
                pushData3.deallocate()
                
                // Because we just called dump() above, to load up contacts2
                expect(config_needs_dump(conf)).to(beFalse())
                
                // Ensure the contact details were updated
                var contact4: contacts_contact = contacts_contact()
                expect(contacts_get(conf2, &contact4, &cDefinitelyRealId)).to(beTrue())
                expect(String(libSessionVal: contact4.name)).to(equal("Joe"))
                expect(String(libSessionVal: contact4.nickname)).to(equal("Joey"))
                expect(contact4.approved).to(beTrue())
                expect(contact4.approved_me).to(beTrue())
                expect(contact4.profile_pic).toNot(beNil()) // Creates an empty instance apparently
                expect(String(libSessionVal: contact4.profile_pic.url)).to(beEmpty())
                expect(contact4.blocked).to(beFalse())
                expect(contact4.created).to(equal(createdTs))
                
                let anotherId: String = "051111111111111111111111111111111111111111111111111111111111111111"
                var cAnotherId: [CChar] = anotherId.cArray.nullTerminated()
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
                
                let pushData4: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData4.pointee.seqno).to(equal(2))
                
                // Check the merging
                let fakeHash2: String = "fakehash2"
                var cFakeHash2: [CChar] = fakeHash2.cArray.nullTerminated()
                var mergeHashes: [UnsafePointer<CChar>?] = [cFakeHash2].unsafeCopy()
                var mergeData: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData4.pointee.config)]
                var mergeSize: [Int] = [pushData4.pointee.config_len]
                expect(config_merge(conf, &mergeHashes, &mergeData, &mergeSize, 1)).to(equal(1))
                config_confirm_pushed(conf2, pushData4.pointee.seqno, &cFakeHash2)
                mergeHashes.forEach { $0?.deallocate() }
                pushData4.deallocate()
                
                expect(config_needs_push(conf)).to(beFalse())
                
                let pushData5: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData5.pointee.seqno).to(equal(2))
                pushData5.deallocate()
                
                // Iterate through and make sure we got everything we expected
                var sessionIds: [String] = []
                var nicknames: [String] = []
                expect(contacts_size(conf)).to(equal(2))
                
                var contact6: contacts_contact = contacts_contact()
                let contactIterator: UnsafeMutablePointer<contacts_iterator> = contacts_iterator_new(conf)
                while !contacts_iterator_done(contactIterator, &contact6) {
                    sessionIds.append(String(libSessionVal: contact6.session_id))
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
                let thirdId: String = "052222222222222222222222222222222222222222222222222222222222222222"
                var cThirdId: [CChar] = thirdId.cArray.nullTerminated()
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
                
                let pushData6: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData6.pointee.seqno).to(equal(3))
                
                let pushData7: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData7.pointee.seqno).to(equal(3))
                
                let pushData6Str: String = String(pointer: pushData6.pointee.config, length: pushData6.pointee.config_len, encoding: .ascii)!
                let pushData7Str: String = String(pointer: pushData7.pointee.config, length: pushData7.pointee.config_len, encoding: .ascii)!
                expect(pushData6Str).toNot(equal(pushData7Str))
                expect([String](pointer: pushData6.pointee.obsolete, count: pushData6.pointee.obsolete_len))
                    .to(equal([fakeHash2]))
                expect([String](pointer: pushData7.pointee.obsolete, count: pushData7.pointee.obsolete_len))
                    .to(equal([fakeHash2]))
                
                let fakeHash3a: String = "fakehash3a"
                var cFakeHash3a: [CChar] = fakeHash3a.cArray.nullTerminated()
                let fakeHash3b: String = "fakehash3b"
                var cFakeHash3b: [CChar] = fakeHash3b.cArray.nullTerminated()
                config_confirm_pushed(conf, pushData6.pointee.seqno, &cFakeHash3a)
                config_confirm_pushed(conf2, pushData7.pointee.seqno, &cFakeHash3b)
                
                var mergeHashes2: [UnsafePointer<CChar>?] = [cFakeHash3b].unsafeCopy()
                var mergeData2: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData7.pointee.config)]
                var mergeSize2: [Int] = [pushData7.pointee.config_len]
                expect(config_merge(conf, &mergeHashes2, &mergeData2, &mergeSize2, 1)).to(equal(1))
                expect(config_needs_push(conf)).to(beTrue())
                
                var mergeHashes3: [UnsafePointer<CChar>?] = [cFakeHash3a].unsafeCopy()
                var mergeData3: [UnsafePointer<UInt8>?] = [UnsafePointer(pushData6.pointee.config)]
                var mergeSize3: [Int] = [pushData6.pointee.config_len]
                expect(config_merge(conf2, &mergeHashes3, &mergeData3, &mergeSize3, 1)).to(equal(1))
                expect(config_needs_push(conf2)).to(beTrue())
                mergeHashes2.forEach { $0?.deallocate() }
                mergeHashes3.forEach { $0?.deallocate() }
                pushData6.deallocate()
                pushData7.deallocate()
                
                let pushData8: UnsafeMutablePointer<config_push_data> = config_push(conf)
                expect(pushData8.pointee.seqno).to(equal(4))
                
                let pushData9: UnsafeMutablePointer<config_push_data> = config_push(conf2)
                expect(pushData9.pointee.seqno).to(equal(pushData8.pointee.seqno))
                
                let pushData8Str: String = String(pointer: pushData8.pointee.config, length: pushData8.pointee.config_len, encoding: .ascii)!
                let pushData9Str: String = String(pointer: pushData9.pointee.config, length: pushData9.pointee.config_len, encoding: .ascii)!
                expect(pushData8Str).to(equal(pushData9Str))
                expect([String](pointer: pushData8.pointee.obsolete, count: pushData8.pointee.obsolete_len))
                    .to(equal([fakeHash3b, fakeHash3a]))
                expect([String](pointer: pushData9.pointee.obsolete, count: pushData9.pointee.obsolete_len))
                    .to(equal([fakeHash3a, fakeHash3b]))
                
                let fakeHash4: String = "fakeHash4"
                var cFakeHash4: [CChar] = fakeHash4.cArray.nullTerminated()
                config_confirm_pushed(conf, pushData8.pointee.seqno, &cFakeHash4)
                config_confirm_pushed(conf2, pushData9.pointee.seqno, &cFakeHash4)
                pushData8.deallocate()
                pushData9.deallocate()
                
                expect(config_needs_push(conf)).to(beFalse())
                expect(config_needs_push(conf2)).to(beFalse())
                
                // Validate the changes
                var sessionIds2: [String] = []
                var nicknames2: [String] = []
                expect(contacts_size(conf)).to(equal(2))
                
                var contact8: contacts_contact = contacts_contact()
                let contactIterator2: UnsafeMutablePointer<contacts_iterator> = contacts_iterator_new(conf)
                while !contacts_iterator_done(contactIterator2, &contact8) {
                    sessionIds2.append(String(libSessionVal: contact8.session_id))
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
    
    // MARK: - Convenience
    
    private static func createContact(
        for index: Int,
        in conf: UnsafeMutablePointer<config_object>?,
        rand: inout ARC4RandomNumberGenerator,
        maxing properties: [ContactProperty] = []
    ) throws -> contacts_contact {
        let postPrefixId: String = "05\(rand.nextBytes(count: 32).toHexString())"
        let sessionId: String = ("05\(index)a" + postPrefixId.suffix(postPrefixId.count - "05\(index)a".count))
        var cSessionId: [CChar] = sessionId.cArray.nullTerminated()
        var contact: contacts_contact = contacts_contact()
        
        guard contacts_get_or_construct(conf, &contact, &cSessionId) else {
            throw SessionUtilError.getOrConstructFailedUnexpectedly
        }
        
        // Set the values to the maximum data that can fit
        properties.forEach { property in
            switch property {
                case .approved: contact.approved = true
                case .approved_me: contact.approved_me = true
                case .blocked: contact.blocked = true
                case .created: contact.created = Int64.max
                case .notifications: contact.notifications = CONVO_NOTIFY_MENTIONS_ONLY
                case .mute_until: contact.mute_until = Int64.max
                
                case .name:
                    contact.name = rand.nextBytes(count: SessionUtil.libSessionMaxNameByteLength)
                        .toHexString()
                        .toLibSession()
                
                case .nickname:
                    contact.nickname = rand.nextBytes(count: SessionUtil.libSessionMaxNameByteLength)
                        .toHexString()
                        .toLibSession()
                    
                case .profile_pic:
                    contact.profile_pic = user_profile_pic(
                        url: rand.nextBytes(count: SessionUtil.libSessionMaxProfileUrlByteLength)
                            .toHexString()
                            .toLibSession(),
                        key: Data(rand.nextBytes(count: 32))
                            .toLibSession()
                    )
            }
        }
        
        return contact
    }
}

fileprivate extension Array where Element == ConfigContactsSpec.ContactProperty {
    static var allProperties: [ConfigContactsSpec.ContactProperty] = ConfigContactsSpec.ContactProperty.allCases
}
