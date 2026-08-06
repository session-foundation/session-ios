// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit
import TestUtilities

import Quick
import Nimble

@testable import SessionNetworkingKit

/// Covers the config expiry detection rule itself - vectors **V1-V9**; the guards and the recovery action - **V9-V13** - are
/// covered by `ConfigRecoverySpec` in `SessionMessagingKitTests`
///
/// These vectors exist because the detection logic is implemented independently on iOS, Android and Desktop rather than being
/// shared in `libSession`, so they are the only thing keeping the three consistent. **Do not relax one to make it pass.**
class ConfigExpiryDetectionSpec: AsyncSpec {
    override class func spec() {
        typealias Detection = Network.StorageServer.ConfigExpiryDetection
        typealias Result = Network.StorageServer.UpdateExpiryResponseResult

        // MARK: Configuration

        let h1: String = "H1"
        let h2: String = "H2"
        let expiry: UInt64 = 1234567890

        @TestState var dependencies: TestDependencies! = TestDependencies()
        @TestState var mockCrypto: MockCrypto! = .create(using: dependencies)

        beforeEach {
            dependencies.set(singleton: .crypto, to: mockCrypto)
        }

        /// An eligible sub-response which updated `updated` and still holds `unchanged`
        func node(updated: [String] = [], unchanged: [String] = []) -> Result {
            return Result(
                changed: updated.reduce(into: [:]) { result, hash in result[hash] = expiry },
                unchanged: unchanged.reduce(into: [:]) { result, hash in result[hash] = expiry },
                didError: false,
                hasUnchangedInfo: true
            )
        }

        /// A sub-response carrying `failed: true`
        func failedNode() -> Result {
            return Result(changed: [:], unchanged: [:], didError: true, hasUnchangedInfo: false)
        }

        /// An eligible sub-response which omitted the `unchanged` key entirely
        func nodeWithNoUnchangedKey(updated: [String]) -> Result {
            return Result(
                changed: updated.reduce(into: [:]) { result, hash in result[hash] = expiry },
                unchanged: [:],
                didError: false,
                hasUnchangedInfo: false
            )
        }

        // MARK: - ConfigExpiryDetection
        describe("ConfigExpiryDetection") {
            // MARK: -- when checking the detection vectors
            context("when checking the detection vectors") {
                // MARK: ---- V1 reports nothing missing when every hash was updated
                it("V1 reports nothing missing when every hash was updated") {
                    let result: Detection = Detection.detect(
                        requestedHashes: [h1, h2],
                        extendWasRequested: true,
                        resultMap: ["A": node(updated: [h1, h2])]
                    )

                    expect(result).to(equal(.checked(missingHashes: [])))
                }

                // MARK: ---- V2 treats an unchanged hash as present
                it("V2 treats an unchanged hash as present") {
                    let result: Detection = Detection.detect(
                        requestedHashes: [h1, h2],
                        extendWasRequested: true,
                        resultMap: ["A": node(updated: [h1], unchanged: [h2])]
                    )

                    expect(result).to(equal(.checked(missingHashes: [])))
                }

                // MARK: ---- V3 marks a hash missing when it is in neither array
                it("V3 marks a hash missing when it is in neither array") {
                    let result: Detection = Detection.detect(
                        requestedHashes: [h1, h2],
                        extendWasRequested: true,
                        resultMap: ["A": node(updated: [h1])]
                    )

                    expect(result).to(equal(.checked(missingHashes: [h2])))
                }

                // MARK: ---- V4 treats one eligible node reporting absence as sufficient
                it("V4 treats one eligible node reporting absence as sufficient") {
                    let result: Detection = Detection.detect(
                        requestedHashes: [h1, h2],
                        extendWasRequested: true,
                        resultMap: [
                            "A": node(updated: [h1]),
                            "B": node(updated: [h1, h2])
                        ]
                    )

                    expect(result).to(equal(.checked(missingHashes: [h2])))
                }

                // MARK: ---- V5 excludes a failed node rather than reading it as absence
                it("V5 excludes a failed node rather than reading it as absence") {
                    let result: Detection = Detection.detect(
                        requestedHashes: [h1, h2],
                        extendWasRequested: true,
                        resultMap: [
                            "A": node(updated: [h1, h2]),
                            "B": failedNode()
                        ]
                    )

                    expect(result).to(equal(.checked(missingHashes: [])))
                }

                // MARK: ---- V6 is inconclusive when every node failed
                it("V6 is inconclusive when every node failed") {
                    let result: Detection = Detection.detect(
                        requestedHashes: [h1, h2],
                        extendWasRequested: true,
                        resultMap: [
                            "A": failedNode(),
                            "B": failedNode()
                        ]
                    )

                    expect(result).to(equal(.inconclusive))
                    expect(result.missingHashes).to(beEmpty())
                }

                // MARK: ---- V7 marks every hash missing when a node holds none of them
                it("V7 marks every hash missing when a node holds none of them") {
                    let result: Detection = Detection.detect(
                        requestedHashes: [h1, h2],
                        extendWasRequested: true,
                        resultMap: ["A": node()]
                    )

                    expect(result).to(equal(.checked(missingHashes: [h1, h2])))
                }

                // MARK: ---- V8 refuses to detect when the request didn't set extend
                it("V8 refuses to detect when the request didn't set extend") {
                    /// **The sub-response is deliberately READABLE, which the real one would not be.** A server that never saw
                    /// `extend` omits `unchanged`, so the production shape satisfies *two* sufficient causes at once - the
                    /// request flag and the absent key - and a fixture carrying both passes with either guard deleted. It would
                    /// then be `V8b` under `V8`'s name.
                    ///
                    /// Handing it a response that *could* be read isolates the claim: we refuse because **we never asked**, not
                    /// because the answer was unusable
                    let result: Detection = Detection.detect(
                        requestedHashes: [h1, h2],
                        extendWasRequested: false,
                        resultMap: ["A": node(updated: [h1])]
                    )

                    expect(result).to(equal(.unavailable))
                    expect(result.missingHashes).to(beEmpty())
                }

                // MARK: ---- V8b refuses to detect when the response omitted unchanged despite extend
                it("V8b refuses to detect when the response omitted unchanged despite extend") {
                    /// **The same verdict as `V8`, reached by the other route.** `V8` arrives via the **request flag** - we know
                    /// we never asked for `unchanged`, so we know the answer can't contain it. `V8b` arrives via the **response
                    /// key** - we did ask, and the node didn't supply it anyway. A parser branching only on the flag passes `V8`
                    /// and fails this; one branching only on the key does the reverse, so neither vector covers the other.
                    ///
                    /// The route matters because the second case is the one that happens in production without anyone changing
                    /// the request: the server silently forces extend-only semantics on a group *member* (whose subaccount lacks
                    /// `Delete`) and omits `unchanged` while our request still says `extend: true`
                    let result: Detection = Detection.detect(
                        requestedHashes: [h1, h2],
                        extendWasRequested: true,
                        resultMap: ["A": nodeWithNoUnchangedKey(updated: [h1])]
                    )

                    /// An absent key means "this response can't answer", never "nothing else is held" - the inverted reading
                    /// reports **every** config gone and re-stores the lot, which is why both halves are asserted
                    expect(result).to(equal(.unavailable))
                    expect(result.missingHashes).to(beEmpty())
                    expect(result.missingHashes).toNot(contain(h2))
                }

                // MARK: ---- V9 evaluates each part of a multipart config independently
                it("V9 evaluates each part of a multipart config independently") {
                    let result: Detection = Detection.detect(
                        requestedHashes: ["P1", "P2", "P3"],
                        extendWasRequested: true,
                        resultMap: ["A": node(updated: ["P1", "P3"])]
                    )

                    /// Only the absent part is missing - and since a config is only healthy when **all** of its parts are
                    /// present, this config is not healthy
                    expect(result).to(equal(.checked(missingHashes: ["P2"])))
                }

                // MARK: ---- V14 is silent when the device holds no active hashes
                it("V14 is silent when the device holds no active hashes") {
                    /// With no active hashes no expire sub-request is sent at all, so there is no response to interpret, and
                    /// the closest `detect` can be asked is with an empty hash list - which must not come back as a conclusive
                    /// "nothing is missing".
                    ///
                    /// **The swarm is deliberately NOT empty.** Asking with no hashes *and* no sub-responses satisfies two
                    /// sufficient causes - the empty ask and the absence of any usable answer - so that fixture returns
                    /// `inconclusive` with the empty-ask guard deleted, and would be testing the swarm instead of the ask. A
                    /// readable node isolates it
                    expect(Detection.detect(requestedHashes: [], extendWasRequested: true, resultMap: ["A": node(updated: [h1])]))
                        .to(equal(.inconclusive))

                    /// The authority for that case is the existing "no config messages in the first poll" check, which this
                    /// detection deliberately does not replace
                }

                // MARK: ---- V15 treats an empty unchanged as a valid answer
                it("V15 treats an empty unchanged as a valid answer") {
                    /// The distinction that V8 relies on, from the other side: with `extend` set the server always assigns
                    /// the key, serialising as `{}` when nothing was unchanged. So `unchanged: {}` is a snode positively
                    /// saying "I hold none of the rest", and conflating it with an absent key would silently disable
                    /// recovery in exactly the total-loss case this feature exists for
                    let present: Detection = Detection.detect(
                        requestedHashes: [h1, h2],
                        extendWasRequested: true,
                        resultMap: ["A": node()]
                    )
                    let absent: Detection = Detection.detect(
                        requestedHashes: [h1, h2],
                        extendWasRequested: true,
                        resultMap: ["A": nodeWithNoUnchangedKey(updated: [])]
                    )

                    expect(present).to(equal(.checked(missingHashes: [h1, h2])))
                    expect(absent).to(equal(.unavailable))
                }
            }

            // MARK: -- when the unchanged key is absent
            context("when the unchanged key is absent") {
                /// **Note:** The single-node case is `V8b` in the vector list above - it used to be repeated here under a prose
                /// name, which is the shape that gets one of a genuine pair deleted as a duplicate. What is left here is the
                /// *mixed* case, which is a different claim
                ///
                // MARK: ---- still detects from the nodes which did report it
                it("still detects from the nodes which did report it") {
                    let result: Detection = Detection.detect(
                        requestedHashes: [h1, h2],
                        extendWasRequested: true,
                        resultMap: [
                            "A": nodeWithNoUnchangedKey(updated: [h1]),
                            "B": node(updated: [h1])
                        ]
                    )

                    expect(result).to(equal(.checked(missingHashes: [h2])))
                }
            }

            // MARK: -- when there is nothing to check
            context("when there is nothing to check") {
                // MARK: ---- is inconclusive for an empty hash list
                it("is inconclusive for an empty hash list") {
                    /// Asking about nothing answers nothing - reporting this as a conclusive "nothing missing" would let it
                    /// override the separate check that actually covers a device holding no config hashes
                    let result: Detection = Detection.detect(
                        requestedHashes: [],
                        extendWasRequested: true,
                        resultMap: ["A": node()]
                    )

                    expect(result).to(equal(.inconclusive))
                }

                // MARK: ---- is inconclusive for an empty swarm
                it("is inconclusive for an empty swarm") {
                    let result: Detection = Detection.detect(
                        requestedHashes: [h1],
                        extendWasRequested: true,
                        resultMap: [:]
                    )

                    expect(result).to(equal(.inconclusive))
                }
            }
        }

        // MARK: - an UpdateExpiryResponse SwarmItem
        describe("an UpdateExpiryResponse SwarmItem") {
            // MARK: -- when decoding
            context("when decoding") {
                // MARK: ---- distinguishes an absent unchanged key from an empty one
                it("distinguishes an absent unchanged key from an empty one") {
                    /// This distinction is the whole basis of the rule above - the storage server only emits `unchanged`
                    /// when the request set `extend` or `shorten`, so defaulting an absent key to `[:]` would make every
                    /// hash it didn't happen to update look expired
                    let withoutKey: Data = "{\"updated\":[\"H1\"],\"expiry\":1}".data(using: .utf8)!
                    let withEmptyKey: Data = "{\"updated\":[\"H1\"],\"unchanged\":{},\"expiry\":1}".data(using: .utf8)!

                    let decodedWithoutKey = try? JSONDecoder()
                        .decode(Network.StorageServer.UpdateExpiryResponse.SwarmItem.self, from: withoutKey)
                    let decodedWithEmptyKey = try? JSONDecoder()
                        .decode(Network.StorageServer.UpdateExpiryResponse.SwarmItem.self, from: withEmptyKey)

                    expect(decodedWithoutKey?.unchanged).to(beNil())
                    expect(decodedWithEmptyKey?.unchanged).to(equal([:]))
                }

                // MARK: ---- decodes the unchanged hashes and their expiries
                it("decodes the unchanged hashes and their expiries") {
                    let jsonData: Data = "{\"updated\":[\"H1\"],\"unchanged\":{\"H2\":99},\"expiry\":1}"
                        .data(using: .utf8)!
                    let decoded = try? JSONDecoder()
                        .decode(Network.StorageServer.UpdateExpiryResponse.SwarmItem.self, from: jsonData)

                    expect(decoded?.updated).to(equal(["H1"]))
                    expect(decoded?.unchanged).to(equal(["H2": 99]))
                }
            }
        }

        // MARK: - a mixed UpdateExpiryResponse
        ///
        /// **This layer, not `detect`, is where iOS decides what counts as an answer.** `detect` receives a `resultMap` in which
        /// every unusable sub-response has already collapsed into `didError`, so a mixed-readability vector written against
        /// `detect` is `V5` under another name. The distinction lives in `validResultMap`, so the vector is asserted from the
        /// wire response down
        describe("a mixed UpdateExpiryResponse") {
            /// The swarm keys have to be hex - the validator feeds them to `Data(hex:)` to check each node's signature
            let readableNode: String = String(repeating: "a", count: 64)
            let unreadableNode: String = String(repeating: "b", count: 64)

            /// One node we can validate and one we cannot, in a single response
            ///
            /// **"Unreadable" here means unvalidatable, which is deliberately *not* the `failed` flag** - that case is `V5`. A
            /// sub-response missing its signature is the distinct route: it arrived, it claims nothing went wrong, and we still
            /// cannot treat anything in it as an answer
            let mixedResponse: Data = """
            {
                "swarm": {
                    "\(readableNode)": {
                        "updated": ["H1"],
                        "unchanged": {},
                        "expiry": 1234567890,
                        "signature": "VGVzdFNpZ25hdHVyZQ=="
                    },
                    "\(unreadableNode)": {
                        "updated": [],
                        "expiry": 1234567890
                    }
                },
                "hf": [19, 3],
                "t": 1234567890
            }
            """.data(using: .utf8)!

            // MARK: -- when one sub-response cannot be validated
            context("when one sub-response cannot be validated") {
                beforeEach {
                    try await mockCrypto
                        .when { $0.verify(.signature(message: .any, publicKey: .any, signature: .any)) }
                        .thenReturn(true)
                }

                // MARK: ---- V8c honours the readable node without counting the unreadable one
                it("V8c honours the readable node without counting the unreadable one") {
                    /// The mixed case neither `V6` nor `V8` reaches: `V6` is every node failing, `V8`/`V8b` are a response which
                    /// can't answer at all. Here one node answers and one is noise, and **both halves have to hold at once** -
                    /// dropping the readable node's verdict disables recovery, while counting the unreadable node's empty arrays
                    /// as absence marks every hash we asked about as gone
                    let response: Network.StorageServer.UpdateExpiryResponse = try JSONDecoder(using: dependencies)
                        .decode(Network.StorageServer.UpdateExpiryResponse.self, from: mixedResponse)
                    let resultMap: [String: Result] = try response.validResultMap(
                        swarmPublicKey: "05\(TestConstants.publicKey)",
                        validationData: [h1, h2],
                        using: dependencies
                    )

                    /// The fixture is what it claims: one usable answer and one unusable one, **both still present in the map**
                    ///
                    /// Retaining the unusable entry matters beyond bookkeeping - `requiredSuccessfulResponses` is `-1`, so
                    /// filtering failures out of the map instead of flagging them would drop the success ratio below 100% and
                    /// throw the *whole* response away, silently disabling detection for any swarm with one bad node
                    expect(resultMap.count).to(equal(2))
                    expect(resultMap[readableNode]?.didError).to(beFalse())
                    expect(resultMap[readableNode]?.hasUnchangedInfo).to(beTrue())
                    expect(resultMap[unreadableNode]?.didError).to(beTrue())

                    let result: Detection = Detection.detect(
                        requestedHashes: [h1, h2],
                        extendWasRequested: true,
                        resultMap: resultMap
                    )

                    /// `H2` missing comes from the readable node; `H1` **not** missing is what proves the unreadable node was
                    /// excluded rather than read as absence
                    expect(result).to(equal(.checked(missingHashes: [h2])))
                    expect(result.missingHashes).toNot(contain(h1))
                }
            }
        }
    }
}
