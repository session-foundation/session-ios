// Copyright © 2026 Session Technology Foundation. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionUtilitiesKit

/// These live in the app-hosted test target because `Mnemonic` reads its word lists from `Bundle.main`, and the
/// lists are members of the `Session` target alone — in an unhosted target, or in either app extension,
/// `Bundle.main` is not the app and every one of them is missing
class MnemonicWordSetSpec: QuickSpec {
    override class func spec() {
        // MARK: Configuration
        
        /// 16 bytes, the seed length the app encodes
        let seed: String = "0123456789abcdef0123456789abcdef"
        
        // MARK: - a Mnemonic word set
        describe("a Mnemonic word set") {
            // MARK: -- loads for every shipped language
            it("loads for every shipped language") {
                /// Each list is its own entry in the app target's resources, so one can go missing on its own
                [Mnemonic.Language.english, .japanese, .portuguese, .spanish].forEach { language in
                    expect { try Mnemonic.encode(hexEncodedString: seed, language: language) }
                        .toNot(throwError())
                }
            }
            
            // MARK: -- round trips a seed through encode and decode
            it("round trips a seed through encode and decode") {
                let encoded: String = try Mnemonic.encode(hexEncodedString: seed)
                
                expect(encoded.components(separatedBy: " ").count).to(equal(13))
                expect(try Mnemonic.decode(mnemonic: encoded)).to(equal(seed))
            }
            
            // MARK: -- produces the first three words as the hash
            it("produces the first three words as the hash") {
                let encoded: String = try Mnemonic.encode(hexEncodedString: seed)
                
                expect(try Mnemonic.hash(hexEncodedString: seed))
                    .to(equal(encoded.components(separatedBy: " ")[0..<3].joined(separator: " ")))
            }
        }
    }
}
