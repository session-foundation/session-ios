// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionUtilitiesKit

class MnemonicSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        /// Not a shipped resource, so `Bundle.main` cannot resolve it on any target
        let missingFilename: String = "not-a-bundled-word-set"
        let unavailable: Mnemonic.Language = Mnemonic.Language(filename: missingFilename, prefixLength: 3)
        
        /// 16 bytes, the seed length the app encodes
        let seed: String = "0123456789abcdef0123456789abcdef"
        let thirteenWords: String = "one two three four five six seven eight nine ten eleven twelve thirteen"
        
        let beResourceMissing: (Mnemonic.WordSetError) -> Void = { error in
            switch error {
                case .resourceMissing(let filename): expect(filename).to(equal(missingFilename))
                default: fail("Expected a resourceMissing error but got \(error)")
            }
        }
        
        // MARK: - Mnemonic
        describe("Mnemonic") {
            // MARK: -- when the word set is unavailable
            context("when the word set is unavailable") {
                // MARK: ---- throws from encode rather than trapping
                it("throws from encode rather than trapping") {
                    expect { try Mnemonic.encode(hexEncodedString: seed, language: unavailable) }
                        .to(throwError(errorType: Mnemonic.WordSetError.self, closure: beResourceMissing))
                }
                
                // MARK: ---- throws from decode rather than trapping
                it("throws from decode rather than trapping") {
                    expect { try Mnemonic.decode(mnemonic: thirteenWords, language: unavailable) }
                        .to(throwError(errorType: Mnemonic.WordSetError.self, closure: beResourceMissing))
                }
                
                // MARK: ---- throws from hash rather than trapping
                it("throws from hash rather than trapping") {
                    expect { try Mnemonic.hash(hexEncodedString: seed, language: unavailable) }
                        .to(throwError(errorType: Mnemonic.WordSetError.self, closure: beResourceMissing))
                }
                
                // MARK: ---- surfaces as nil to a caller using try?
                it("surfaces as nil to a caller using try?") {
                    /// `ConversationVC` reads the recovery phrase through `try?` on the send path, so this is the
                    /// behaviour that keeps an unavailable word set from blocking every send
                    expect(try? Mnemonic.encode(hexEncodedString: seed, language: unavailable)).to(beNil())
                }
            }
        }
    }
}
