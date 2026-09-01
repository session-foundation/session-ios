// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation

import Quick
import Nimble

@testable import SessionNetworkingKit

/// The download url is the only thing that tells a reader which encryption a file used, so a client that writes
/// the fragment in a spelling this parser does not recognise uploads content we silently treat as plaintext.
class FileServerParsedDownloadUrlSpec: QuickSpec {
    override class func spec() {
        // MARK: - a FileServer ParsedDownloadUrl
        describe("a FileServer ParsedDownloadUrl") {
            // MARK: -- when detecting stream encryption
            context("when detecting stream encryption") {
                // MARK: ---- does not want stream decryption with no fragment
                it("does not want stream decryption with no fragment") {
                    let result = Network.FileServer.parsedDownloadUrl(
                        for: "http://filev2.getsession.org/file/abc123"
                    )
                    
                    expect(result?.fileId).to(equal("abc123"))
                    expect(result?.wantsStreamDecryption).to(beFalse())
                }
                
                // MARK: ---- wants stream decryption for a bare d fragment
                it("wants stream decryption for a bare d fragment") {
                    let result = Network.FileServer.parsedDownloadUrl(
                        for: "http://filev2.getsession.org/file/abc123#d"
                    )
                    
                    expect(result?.wantsStreamDecryption).to(beTrue())
                }
                
                // MARK: ---- wants stream decryption alongside a custom pubkey in either order
                it("wants stream decryption alongside a custom pubkey in either order") {
                    let pubkey: String = "0123456789abcdef0123456789abcdef00000000000000000000000000000000"
                    
                    expect(
                        Network.FileServer
                            .parsedDownloadUrl(for: "http://example.com/file/abc123#d&p=\(pubkey)")?
                            .wantsStreamDecryption
                    ).to(beTrue())
                    expect(
                        Network.FileServer
                            .parsedDownloadUrl(for: "http://example.com/file/abc123#p=\(pubkey)&d")?
                            .wantsStreamDecryption
                    ).to(beTrue())
                }
                
                // MARK: ---- does not want stream decryption for a d= fragment
                it("does not want stream decryption for a d= fragment") {
                    /// Session Desktop builds this fragment with `URLSearchParams`, which serialises a valueless key
                    /// as `d=`; libSession compares the fragment against `d` exactly, so we do not recognise it.
                    ///
                    /// This expectation is the divergence, not the intent — flip it when libSession accepts both
                    /// spellings, and see `FileServerApis.parseAttachmentUrl` on Android for the shape of that fix.
                    let result = Network.FileServer.parsedDownloadUrl(
                        for: "http://filev2.getsession.org/file/abc123#d="
                    )
                    
                    expect(result).toNot(beNil())
                    expect(result?.fileId).to(equal("abc123"))
                    expect(result?.wantsStreamDecryption).to(beFalse())
                }
                
                // MARK: ---- does not want stream decryption for a d= fragment beside a custom pubkey
                it("does not want stream decryption for a d= fragment beside a custom pubkey") {
                    let result = Network.FileServer.parsedDownloadUrl(
                        for: "http://example.com/file/abc123#p=0123456789abcdef0123456789abcdef00000000000000000000000000000000&d="
                    )
                    
                    expect(result?.customPubkeyHex)
                        .to(equal("0123456789abcdef0123456789abcdef00000000000000000000000000000000"))
                    expect(result?.wantsStreamDecryption).to(beFalse())
                }
            }
        }
    }
}
