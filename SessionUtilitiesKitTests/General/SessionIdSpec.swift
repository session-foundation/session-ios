// Copyright © 2022 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionUtilitiesKit

class SessionIdSpec: QuickSpec {
    override class func spec() {
        // MARK: - a SessionId
        describe("a SessionId") {
            // MARK: -- when initializing
            context("when initializing") {
                // MARK: ---- with an idString
                context("with an idString") {
                    // MARK: ------ succeeds when correct
                    it("succeeds when correct") {
                        let sessionId: SessionId? = SessionId(from: "05\(TestConstants.publicKey)")
                        
                        expect(sessionId?.prefix).to(equal(.standard))
                        expect(sessionId?.publicKey).to(equal(TestConstants.publicKey))
                    }
                    
                    // MARK: ------ fails when too short
                    it("fails when too short") {
                        expect(SessionId(from: "")).to(beNil())
                    }
                    
                    // MARK: ------ fails with an invalid prefix
                    it("fails with an invalid prefix") {
                        expect(SessionId(from: "AB\(TestConstants.publicKey)")).to(beNil())
                    }
                }
                
                // MARK: ---- with a prefix and publicKey
                context("with a prefix and publicKey") {
                    // MARK: ------ converts the bytes into a hex string
                    it("converts the bytes into a hex string") {
                        let sessionId: SessionId? = SessionId(.standard, publicKey: [0, 1, 2, 3, 4, 5, 6, 7, 8])
                        
                        expect(sessionId?.prefix).to(equal(.standard))
                        expect(sessionId?.publicKey).to(equal("000102030405060708"))
                    }
                }
            }
            
            // MARK: -- generates the correct hex string
            it("generates the correct hex string") {
                expect(SessionId(.unblinded, publicKey: Data(hex: TestConstants.publicKey).bytes).hexString)
                    .to(equal("0088672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"))
                expect(SessionId(.standard, publicKey: Data(hex: TestConstants.publicKey).bytes).hexString)
                    .to(equal("0588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"))
                expect(SessionId(.blinded15, publicKey: Data(hex: TestConstants.publicKey).bytes).hexString)
                    .to(equal("1588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"))
                expect(SessionId(.blinded25, publicKey: Data(hex: TestConstants.publicKey).bytes).hexString)
                    .to(equal("2588672ccb97f40bb57238989226cf429b575ba355443f47bc76c5ab144a96c65b"))
            }
        }
        
        // MARK: - a SessionId Prefix
        describe("a SessionId Prefix") {
            // MARK: -- when initializing
            context("when initializing") {
                // MARK: ---- with just a prefix
                context("with just a prefix") {
                    // MARK: ------ succeeds when valid
                    it("succeeds when valid") {
                        expect(SessionId.Prefix(from: "00")).to(equal(.unblinded))
                        expect(SessionId.Prefix(from: "05")).to(equal(.standard))
                        expect(SessionId.Prefix(from: "15")).to(equal(.blinded15))
                        expect(SessionId.Prefix(from: "25")).to(equal(.blinded25))
                    }
                    
                    // MARK: ------ fails when nil
                    it("fails when nil") {
                        expect(SessionId.Prefix(from: nil)).to(beNil())
                    }
                    
                    // MARK: ------ fails when invalid
                    it("fails when invalid") {
                        expect(SessionId.Prefix(from: "AB")).to(beNil())
                    }
                }
                
                // MARK: ---- with a longer string
                context("with a longer string") {
                    // MARK: ------ fails with invalid hex
                    it("fails with invalid hex") {
                        expect(SessionId.Prefix(from: "Hello!!!")).to(beNil())
                    }
                    
                    // MARK: ------ fails with the wrong length
                    it("fails with the wrong length") {
                        expect(SessionId.Prefix(from: String(TestConstants.publicKey.prefix(10)))).to(beNil())
                    }
                    
                    // MARK: ------ fails with an invalid prefix
                    it("fails with an invalid prefix") {
                        expect(SessionId.Prefix(from: "AB\(TestConstants.publicKey)")).to(beNil())
                    }
                }
            }
        }
    }
}
