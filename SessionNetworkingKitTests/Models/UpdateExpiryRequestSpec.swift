// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit
import TestUtilities

import Quick
import Nimble

@testable import SessionNetworkingKit

/// These assert what actually reaches **the wire**, not what the caller passed in
///
/// That distinction is the whole point: `updateExpiry` accepted `shortenOnly`/`extendOnly` and silently dropped both on the
/// way to the request for as long as they had existed, and no test of the caller's arguments or of the request type in
/// isolation would have caught it. The same shape of bug (a flag accepted at one layer and not forwarded to the next) has now
/// been found independently on iOS and Desktop, so the assertion has to be made against the encoded body.
class UpdateExpiryRequestSpec: AsyncSpec {
    override class func spec() {
        // MARK: Configuration

        @TestState var dependencies: TestDependencies! = TestDependencies { dependencies in
            dependencies.dateNow = Date(timeIntervalSince1970: 1234567890)
            dependencies.forceSynchronous = true
        }
        @TestState var mockNetwork: MockNetwork! = .create(using: dependencies)
        @TestState var authMethod: AuthenticationMethod! = TestAuthentication()

        beforeEach {
            dependencies.set(singleton: .network, to: mockNetwork)
            try await mockNetwork.defaultInitialSetup(using: dependencies)
        }

        /// Run `updateExpiry` and hand back the JSON body that was actually sent
        ///
        /// The stubbed network throws, which is fine - the body has already been encoded by then, and it keeps the test to
        /// the one thing it is asserting
        func sentBody(shortenOnly: Bool? = nil, extendOnly: Bool? = nil) async -> String? {
            _ = try? await Network.StorageServer.updateExpiry(
                serverHashes: ["H1"],
                updatedExpiryMs: 1234567890,
                shortenOnly: shortenOnly,
                extendOnly: extendOnly,
                updateExpiryDates: { _, _ in },
                authMethod: authMethod,
                using: dependencies
            )

            let info = await mockNetwork.verify {
                try await $0.send(
                    endpoint: MockEndpoint.any,
                    destination: .any,
                    body: .any,
                    category: .any,
                    requestTimeout: .any,
                    overallTimeout: .any
                )
            }.wasCalled(atLeast: 1)
            let body: String? = info?.matchingCalls.first?.parameterSummary

            /// Prove a real `expire` request reached the wire before any caller inspects it
            ///
            /// Without this, a `nil` body would satisfy every `toNot(contain:)` assertion in this file - and the "sends
            /// neither flag" case is made **entirely** of those, so it would pass while measuring nothing at all. The
            /// `try?` above deliberately swallows the send failure (the body is already encoded by then), which means
            /// nothing else here would notice a request that was never built
            /// Prove this is really the `expire` request before any caller inspects the flags
            ///
            /// **Note:** `wasCalled(atLeast: 1)` above is itself an assertion, so it already fails if no send happened -
            /// the file was never vulnerable to a `nil` body the way its `toNot(contain:)`-only test suggested. These add
            /// the part `wasCalled` cannot give: that the captured call is *this* request rather than merely some request
            expect(body).to(contain("H1"))
            expect(body).to(contain("expiry"))

            return body
        }

        // MARK: - an updateExpiry request
        describe("an updateExpiry request") {
            // MARK: -- when told to extend only
            context("when told to extend only") {
                // MARK: ---- puts extend on the wire
                it("puts extend on the wire") {
                    let body: String? = await sentBody(extendOnly: true)

                    expect(body).to(contain("\"extend\":true"))
                    expect(body).toNot(contain("\"shorten\""))
                }
            }

            // MARK: -- when told to shorten only
            context("when told to shorten only") {
                // MARK: ---- puts shorten on the wire
                it("puts shorten on the wire") {
                    /// Without this the server sets the expiry literally and never returns `unchanged`, which is what left
                    /// `ExpirationUpdateJob`'s disappearing-message timer restart as dead code
                    let body: String? = await sentBody(shortenOnly: true)

                    expect(body).to(contain("\"shorten\":true"))
                    expect(body).toNot(contain("\"extend\""))
                }
            }

            // MARK: -- when told neither
            context("when told neither") {
                // MARK: ---- sends neither flag
                it("sends neither flag") {
                    let body: String? = await sentBody()

                    expect(body).toNot(contain("\"shorten\""))
                    expect(body).toNot(contain("\"extend\""))
                }
            }
        }

        // MARK: - the signature
        describe("the signature") {
            // MARK: -- covers the shorten/extend flag
            it("covers the shorten/extend flag") {
                /// The server signs over `("expire" || ShortenOrExtend || expiry || messages...)`, so the flag has to be
                /// part of the signed material or the request is rejected once it's actually sent
                let base: [UInt8] = Network.StorageServer.UpdateExpiryRequest(
                    messageHashes: ["H1"],
                    expiryMs: 1,
                    authMethod: authMethod
                ).verificationBytes
                let extend: [UInt8] = Network.StorageServer.UpdateExpiryRequest(
                    messageHashes: ["H1"],
                    expiryMs: 1,
                    extend: true,
                    authMethod: authMethod
                ).verificationBytes
                let shorten: [UInt8] = Network.StorageServer.UpdateExpiryRequest(
                    messageHashes: ["H1"],
                    expiryMs: 1,
                    shorten: true,
                    authMethod: authMethod
                ).verificationBytes

                expect(extend).toNot(equal(base))
                expect(shorten).toNot(equal(base))
                expect(extend).toNot(equal(shorten))
                expect(String(decoding: extend)).to(contain("extend"))
                expect(String(decoding: shorten)).to(contain("shorten"))
            }
        }
    }
}

// MARK: - Convenience

/// Signs with a fixed value - this spec is about what reaches the wire, not about the signature itself
///
/// **Note:** `Authentication.standard` lives in `SessionMessagingKit`, which this target can't see
private struct TestAuthentication: AuthenticationMethod {
    var info: Authentication.Info {
        .standard(
            sessionId: SessionId(.standard, hex: TestConstants.publicKey),
            ed25519PublicKey: Array(Data(hex: TestConstants.edPublicKey))
        )
    }

    func generateSignature(
        with verificationBytes: [UInt8],
        using dependencies: Dependencies
    ) throws -> Authentication.Signature {
        return .standard(signature: Array("TestSignature".data(using: .utf8)!))
    }
}

private func String(decoding bytes: [UInt8]) -> String {
    return (Swift.String(data: Data(bytes), encoding: .utf8) ?? "")
}
