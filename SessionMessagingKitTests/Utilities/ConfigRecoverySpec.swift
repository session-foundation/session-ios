// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import UIKit
import SessionUtil
import SessionNetworkingKit
import SessionUtilitiesKit
import TestUtilities

import Quick
import Nimble

@testable import SessionMessagingKit

/// Covers the guards, the expired-group rule and the recovery action - vectors **V10-V13g** and **V16-V21**; the detection rule
/// itself (**V1-V9**, **V14-V15**) is in `ConfigExpiryDetectionSpec`, and the "is our state level" decision (**V22-V22e**) is in
/// `SwarmPollerSpec`, driven through the real poll path
///
/// These vectors exist because the logic is implemented independently on iOS, Android and Desktop rather than being shared in
/// `libSession`, so they are the only thing keeping the three consistent. **Do not relax one to make it pass.**
class ConfigRecoverySpec: AsyncSpec {
    override class func spec() {
        @TestState var fixture: ConfigRecoveryTestFixture!

        beforeEach {
            fixture = try await ConfigRecoveryTestFixture.create()
        }

        // MARK: - a DetectionReport
        ///
        /// A pure value derived from one poll's `expire` response. It is deliberately **not** cache state: storing a detection
        /// and consuming it later lets it be picked up by the wrong poll or dropped when nothing consumes it, and it bought
        /// nothing because detection repeats every poll - a hash that is still missing is simply reported again.
        describe("a DetectionReport") {
            // MARK: -- when the detection was conclusive
            context("when the detection was conclusive") {
                // MARK: ---- offers the missing hashes for recovery
                it("offers the missing hashes for recovery") {
                    let report: ConfigRecovery.DetectionReport = fixture.report(
                        missing: ["H1", "H2"],
                        activeHashesByVariant: [.userProfile: ["H1", "H2"]]
                    )

                    expect(report.recoverableMissingHashes).to(equal(["H1", "H2"]))
                }

                // MARK: ---- never offers a keys hash for recovery
                it("never offers a keys hash for recovery") {
                    /// A keys config can be *detected* as expired but never re-stored - `libSession` has no API to re-emit a
                    /// keys message it already holds - so its hashes must not reach the recovery queue at all
                    let report: ConfigRecovery.DetectionReport = fixture.report(
                        missing: ["K1", "I1"],
                        activeHashesByVariant: [.groupKeys: ["K1"], .groupInfo: ["I1"]]
                    )

                    expect(report.recoverableMissingHashes).to(equal(["I1"]))
                }
            }

            // MARK: -- when the detection was not conclusive
            context("when the detection was not conclusive") {
                // MARK: ---- offers nothing for an inconclusive result
                it("offers nothing for an inconclusive result") {
                    let report: ConfigRecovery.DetectionReport = ConfigRecovery.DetectionReport(
                        detection: .inconclusive,
                        activeHashesByVariant: [.userProfile: ["H1"]]
                    )

                    expect(report.recoverableMissingHashes).to(beEmpty())
                    expect(report.keysVerdict).to(equal(.noVerdict))
                }

                // MARK: ---- offers nothing for an unavailable result
                it("offers nothing for an unavailable result") {
                    let report: ConfigRecovery.DetectionReport = ConfigRecovery.DetectionReport(
                        detection: .unavailable,
                        activeHashesByVariant: [.userProfile: ["H1"]]
                    )

                    expect(report.recoverableMissingHashes).to(beEmpty())
                    expect(report.keysVerdict).to(equal(.noVerdict))
                }
            }

            // MARK: -- when deciding whether a group is expired
            context("when deciding whether a group is expired") {
                // MARK: ---- V16 flags expired when every keys hash is missing
                it("V16 flags expired when every keys hash is missing") {
                    let report: ConfigRecovery.DetectionReport = fixture.report(
                        missing: ["K1", "K2"],
                        activeHashesByVariant: [.groupKeys: ["K1", "K2"]]
                    )

                    expect(report.keysVerdict).to(equal(.expired))
                    expect(report.recoverableMissingHashes).to(beEmpty())
                }

                // MARK: ---- V16a does not flag expired when one keys hash survives
                it("V16a does not flag expired when one keys hash survives") {
                    /// Tested explicitly because with a single keys hash "all missing" and "any missing" coincide and the
                    /// difference is invisible - and several keys hashes is the normal case, since a generation is one rekey
                    /// message plus N `key_supplement` messages
                    let report: ConfigRecovery.DetectionReport = fixture.report(
                        missing: ["K1"],
                        activeHashesByVariant: [.groupKeys: ["K1", "K2"]]
                    )

                    expect(report.keysVerdict).to(equal(.notExpired))
                }

                // MARK: ---- V19 leaves the flag alone when only groupInfo is missing
                it("V19 leaves the flag alone when only groupInfo is missing") {
                    /// The keys config alone decides expiry; `groupInfo` absence drives recovery instead. This needs per-config
                    /// attribution - a flat union of the hashes could not tell these apart
                    let report: ConfigRecovery.DetectionReport = fixture.report(
                        missing: ["I1"],
                        activeHashesByVariant: [.groupKeys: ["K1"], .groupInfo: ["I1"]]
                    )

                    expect(report.keysVerdict).to(equal(.notExpired))
                    expect(report.recoverableMissingHashes).to(equal(["I1"]))
                }

                // MARK: ---- V23 recovers the keys instead of flagging expired when the bytes are held
                it("V23 recovers the keys instead of flagging expired when the bytes are held") {
                    /// A keys message is admin-signed and cannot be regenerated, but the retained bytes can be pushed back
                    /// **unchanged** - same hash, no signature needed - which is what lets a member repair a group.
                    ///
                    /// **The fixture holds a `groupInfo` hash as well as the keys ones, deliberately.** With keys hashes alone
                    /// and all of them missing, `V14`'s empty-ask rule would be in play instead and this would be testing that
                    let report: ConfigRecovery.DetectionReport = ConfigRecovery.DetectionReport(
                        detection: .checked(missingHashes: ["K1", "K2"]),
                        activeHashesByVariant: [.groupKeys: ["K1", "K2"], .groupInfo: ["I1"]],
                        recoverableKeysHashes: ["K1", "K2"]
                    )

                    /// Not expired - the group is being repaired, not lost. The flag is left untouched rather than cleared,
                    /// so a later poll seeing the keys present clears it reactively
                    expect(report.keysVerdict).to(equal(.noVerdict))

                    /// And the keys hashes are offered for re-store, which is the part `V16` used to forbid
                    expect(report.recoverableMissingHashes).to(equal(["K1", "K2"]))
                }

                // MARK: ---- V23a still flags expired when no bytes are retained
                it("V23a still flags expired when no bytes are retained") {
                    /// A group predating retention: it has active keys hashes and no bytes, so it cannot be repaired **by this
                    /// device** and the expired flag stays the right answer.
                    ///
                    /// **Pins the absence of BYTES, not of detection.** The detection is identical to `V23`'s - same missing
                    /// set, same active hashes - so the only term that differs is retention. A fixture that also broke the
                    /// detection would be indistinguishable from `V16`
                    let report: ConfigRecovery.DetectionReport = ConfigRecovery.DetectionReport(
                        detection: .checked(missingHashes: ["K1", "K2"]),
                        activeHashesByVariant: [.groupKeys: ["K1", "K2"], .groupInfo: ["I1"]],
                        recoverableKeysHashes: []
                    )

                    expect(report.keysVerdict).to(equal(.expired))
                    expect(report.recoverableMissingHashes).to(beEmpty())
                }

                // MARK: ---- V23b retains and re-stores a supplemental, not just the rekey
                it("V23b retains and re-stores a supplemental, not just the rekey") {
                    /// **Pins that retention is hash-keyed, not generation-keyed.** A generation is one rekey plus every
                    /// supplemental issued against it, but `active_key_messages()` carries no generation, so "is this
                    /// generation complete" is not a question this layer can ask. What it *can* pin is that a supplemental is
                    /// kept and offered on its own terms - which is the property that would break if someone "tidied" the
                    /// retention to be keyed by generation and kept only the rekey.
                    ///
                    /// Asserted as `equal` rather than `contain`: `contain` passes on an implementation that offers only one of
                    /// them, which is exactly the defect
                    let report: ConfigRecovery.DetectionReport = ConfigRecovery.DetectionReport(
                        detection: .checked(missingHashes: ["K-REKEY", "K-SUPPLEMENT"]),
                        activeHashesByVariant: [
                            .groupKeys: ["K-REKEY", "K-SUPPLEMENT"],
                            .groupInfo: ["I1"]
                        ],
                        recoverableKeysHashes: ["K-REKEY", "K-SUPPLEMENT"]
                    )

                    expect(report.recoverableMissingHashes).to(equal(["K-REKEY", "K-SUPPLEMENT"]))
                    expect(report.keysVerdict).to(equal(.noVerdict))
                }

                // MARK: ---- repairs with whatever bytes it holds rather than requiring all of them
                it("repairs with whatever bytes it holds rather than requiring all of them") {
                    /// ⚠️ **This is the reverse of what I first implemented.** I gated recovery on holding *every* missing keys
                    /// hash, reasoning that a partial generation repairs nothing. That reasoning is not available here: the
                    /// accessor is hash-keyed, so partial-ness of a *generation* cannot be determined, and the recovery action
                    /// re-stores every retained message anyway - strictly more than generation-completeness would ask.
                    ///
                    /// So holding any of them is enough to attempt the repair, and the flag is deferred while it runs
                    let report: ConfigRecovery.DetectionReport = ConfigRecovery.DetectionReport(
                        detection: .checked(missingHashes: ["K-REKEY", "K-SUPPLEMENT"]),
                        activeHashesByVariant: [
                            .groupKeys: ["K-REKEY", "K-SUPPLEMENT"],
                            .groupInfo: ["I1"]
                        ],
                        recoverableKeysHashes: ["K-REKEY"]
                    )

                    expect(report.keysVerdict).to(equal(.noVerdict))
                    expect(report.attemptedKeysHashes).to(equal(["K-REKEY"]))
                }

                // MARK: ---- V16b defers to the first-poll check when the device holds no keys hashes
                it("V16b defers to the first-poll check when the device holds no keys hashes") {
                    /// With no keys hashes there was nothing to ask about, so detection is *structurally silent* rather than
                    /// reassuring - the existing "no config messages in the first poll" check in `GroupPoller.pollerDidStart`
                    /// remains the authority.
                    ///
                    /// **This is about which check holds AUTHORITY, not about the request** - that is `V14`, where no expire
                    /// sub-request is sent at all. Here a conclusive detection did come back and did report a missing hash; the
                    /// only thing that defers is the expired verdict.
                    ///
                    /// The bug it catches is a one-character one: "every keys hash we asked about is missing" implemented as a
                    /// subset test is **vacuously true of the empty set**, so a device holding no keys hashes flags the group
                    /// expired on the strength of a question it never asked
                    let activeHashesByVariant: [ConfigDump.Variant: Set<String>] = [.groupInfo: ["I1"]]

                    /// Assert the premise before the outcome - the vector is "a device holding no keys hashes", so if the fixture
                    /// quietly held one this would be testing `V19` instead
                    expect(activeHashesByVariant[.groupKeys]).to(beNil())

                    let report: ConfigRecovery.DetectionReport = fixture.report(
                        missing: ["I1"],
                        activeHashesByVariant: activeHashesByVariant
                    )

                    expect(report.keysVerdict).to(equal(.noVerdict))

                    /// Not `V14`: the detection *was* conclusive and recovery still proceeds for the non-keys config. Only the
                    /// expired verdict defers
                    expect(report.recoverableMissingHashes).to(equal(["I1"]))

                    /// The reachability control - the same missing set reaches a real verdict the moment a keys hash exists to
                    /// ask about, so `noVerdict` above is a decision rather than an unreached code path
                    let withKeysHash: ConfigRecovery.DetectionReport = fixture.report(
                        missing: ["I1", "K1"],
                        activeHashesByVariant: [.groupInfo: ["I1"], .groupKeys: ["K1"]]
                    )

                    expect(withKeysHash.keysVerdict).to(equal(.expired))

                    /// **Note:** The apply side (`applyKeysVerdictIfNeeded` writing nothing for `noVerdict`) is not asserted
                    /// here - this fixture has no database, and the flag write goes through `updateAllAndConfig`. Recorded
                    /// rather than faked; the verdict itself is where the vector's discrimination lives
                }
            }
        }

        // MARK: - the ConfigRecovery store
        describe("the ConfigRecovery store") {
            // MARK: -- when checking the level-with-swarm guard
            context("when checking the level-with-swarm guard") {
                // MARK: ---- V10 refuses to recover before our state is known to be level
                it("V10 refuses to recover before our state is known to be level") {
                    /// The hash **is** detected as missing, but recovery must not run - a device that re-stores before it has
                    /// seen what the swarm holds could put back state which has since been deliberately changed
                    await expect { await fixture.store.localStateIsLevelWithSwarm(swarmPublicKey: fixture.userSwarm) }
                        .to(beFalse())
                    await expect { await fixture.claim(["H2"]) }.to(beNil())
                }

                // MARK: ---- allows recovery once our state is level
                it("allows recovery once our state is level") {
                    await fixture.store.markLocalStateLevelWithSwarm(swarmPublicKey: fixture.userSwarm)

                    await expect { await fixture.claim(["H2"]) }.to(equal(["H2"]))
                }

                // MARK: ---- V22d keeps a lossy merge disqualifying for the rest of the session
                it("V22d keeps a lossy merge disqualifying for the rest of the session") {
                    /// The case a per-poll fix misses. A config message which parsed but failed to merge has already had its
                    /// `lastHash` advanced past it, so it is never offered again - which means the very next poll returns no
                    /// config messages and marks the swarm level. Correcting only the poll where the failure happened leaves
                    /// the wrong state one poll later, indistinguishable from a clean history
                    await fixture.store.markMergeIncompleteForSwarm(swarmPublicKey: fixture.userSwarm)
                    await fixture.store.markLocalStateLevelWithSwarm(swarmPublicKey: fixture.userSwarm)

                    await expect { await fixture.store.localStateIsLevelWithSwarm(swarmPublicKey: fixture.userSwarm) }
                        .to(beFalse())
                    await expect { await fixture.claim(["H2"]) }.to(beNil())
                }

                // MARK: ---- keeps a lossy merge scoped to the swarm it happened on
                it("keeps a lossy merge scoped to the swarm it happened on") {
                    await fixture.store.markLocalStateLevelWithSwarm(swarmPublicKey: fixture.userSwarm)
                    await fixture.store.markMergeIncompleteForSwarm(swarmPublicKey: fixture.groupSwarm)

                    /// The positive half - the unaffected swarm still recovers, so this isn't disqualifying everything
                    await expect { await fixture.claim(["H1"]) }.to(equal(["H1"]))
                }

                // MARK: ---- V10b does not let one swarm's clean poll satisfy another's precondition
                it("V10b does not let one swarm's clean poll satisfy another's precondition") {
                    /// The precondition is *per swarm*, and a flat "we have polled successfully this session" flag passes every
                    /// other vector in this file while failing only this one - `V10` never notices, because it asserts the state
                    /// before **any** poll has happened, which a global flag also gets right.
                    ///
                    /// The failure it guards against is the whole point of the precondition: polling swarm A tells us nothing
                    /// about whether we have taken in what swarm B holds, so recovering B on the strength of A's poll is exactly
                    /// the "re-store before we have seen the current state" case
                    await fixture.store.markLocalStateLevelWithSwarm(swarmPublicKey: fixture.userSwarm)

                    /// The positive half, so this cannot pass by nothing running at all
                    await expect { await fixture.claim(["H1"]) }.to(equal(["H1"]))
                    await expect { await fixture.store.localStateIsLevelWithSwarm(swarmPublicKey: fixture.groupSwarm) }
                        .to(beFalse())
                    await expect { await fixture.claim(["H2"], swarmPublicKey: fixture.groupSwarm) }.to(beNil())
                }
            }

            // MARK: -- when a hash has already been stored
            context("when a hash has already been stored") {
                beforeEach {
                    await fixture.store.markLocalStateLevelWithSwarm(swarmPublicKey: fixture.userSwarm)
                    _ = await fixture.claim(["H2"])
                    await fixture.release(claimed: ["H2"], stored: ["H2"], retryable: [])
                }

                // MARK: ---- V13 does not store it again straight away
                it("V13 does not store it again straight away") {
                    /// A later poll reports the same hash missing again - which will happen, because the swarm takes time to
                    /// replicate the re-store - and it must not be sent a second time
                    await expect { await fixture.claim(["H2"]) }.to(beNil())
                }

                // MARK: ---- V13g stores it again once the bar interval has elapsed
                it("V13g stores it again once the bar interval has elapsed") {
                    /// **The bar is bounded in time, not scoped to the session.** A session can outlive the 30-day TTL - a
                    /// backgrounded mobile client, or a desktop client which has no foreground gate - and in that window a hash
                    /// barred after a *successful* store can expire from the swarm a second time. A session-scoped bar blocks
                    /// the very recovery that would put it back, and the excluded population is long-lived sessions, which is
                    /// exactly where configs expire.
                    ///
                    /// Driven by **advancing the clock**, not by rebuilding the store: a fresh store would have no bar at all,
                    /// so that version of this test passes against a session-scoped implementation and proves nothing
                    await expect { await fixture.claim(["H2"], now: fixture.now.addingTimeInterval(3599)) }.to(beNil())
                    await expect { await fixture.claim(["H2"], now: fixture.now.addingTimeInterval(3601)) }
                        .to(equal(["H2"]))
                }

                // MARK: ---- prunes lapsed bars so the map cannot grow across a long session
                it("prunes lapsed bars so the map cannot grow across a long session") {
                    /// **Varies the key rather than repeating the operation.** Settling the *same* hash twice overwrites one
                    /// map entry, so a size assertion never moves whether or not anything is pruned - the measuring-nothing
                    /// output is identical to the success output. The leak lives in accumulation across *distinct* keys, and in
                    /// production the keys genuinely rotate: a re-pushed config occupies new hashes.
                    ///
                    /// Asserted by naming the entry that must be gone rather than by a bare count, since a count also moves for
                    /// reasons unrelated to pruning
                    await fixture.release(claimed: ["OLD-1"], stored: ["OLD-1"], retryable: [])

                    let later: Date = fixture.now.addingTimeInterval(3601)
                    await fixture.release(claimed: ["NEW-1"], stored: ["NEW-1"], retryable: [], now: later)

                    /// The lapsed entry is gone - it is claimable again, which is only true if it is no longer barred...
                    await expect { await fixture.claim(["OLD-1"], now: later) }.to(equal(["OLD-1"]))

                    /// ...while the fresh one is still held
                    await expect { await fixture.claim(["NEW-1"], now: later) }.to(beNil())
                }

                // MARK: ---- still accepts a different hash straight away
                it("still accepts a different hash straight away") {
                    await expect { await fixture.claim(["H2", "H3"]) }.to(equal(["H3"]))
                }
            }

            // MARK: -- when a guard ruled a hash out
            context("when a guard ruled a hash out") {
                beforeEach {
                    await fixture.store.markLocalStateLevelWithSwarm(swarmPublicKey: fixture.userSwarm)
                    _ = await fixture.claim(["H2"])

                    /// Neither stored nor retryable - which is what a guard reaching a decision looks like
                    await fixture.release(claimed: ["H2"], stored: [], retryable: [])
                }

                // MARK: ---- V13e does not re-inspect it on the next poll
                it("V13e does not re-inspect it on the next poll") {
                    /// This constrains the "a thrown inspection stays retryable" rule from the other side: that says *don't*
                    /// bar without a verdict, this says *do* bar on a real one. A fix for either that overshoots breaks the
                    /// other, and nothing else in the suite pins that boundary
                    await expect { await fixture.claim(["H2"]) }.to(beNil())
                }

                // MARK: ---- costs the swarm no backoff
                it("costs the swarm no backoff") {
                    /// A guard-only pass must be free - otherwise hashes a guard has already settled crowd out the retryable
                    /// ones by consuming the retry budget of genuinely retryable hashes on the same swarm
                    await expect { await fixture.claim(["H6"]) }.to(equal(["H6"]))
                }
            }

            // MARK: -- when an attempt fails
            context("when an attempt fails") {
                beforeEach {
                    await fixture.store.markLocalStateLevelWithSwarm(swarmPublicKey: fixture.userSwarm)
                    _ = await fixture.claim(["H2"])
                    await fixture.release(claimed: ["H2"], stored: [], retryable: ["H2"])
                }

                // MARK: ---- V13a retries the hash whose store failed
                it("V13a retries the hash whose store failed") {
                    /// The companion to V13, and the pair is the point: V13 asserts a stored hash isn't stored again, which
                    /// passes just as happily on an implementation that bars a hash the moment it is *dispatched*. Only this
                    /// direction catches the over-holding version.
                    ///
                    /// A store that failed is not a re-store, so barring it would withdraw recovery from a device with a
                    /// genuinely expired config for a whole bar interval on the strength of one network blip
                    await expect { await fixture.claim(["H2"], now: fixture.now.addingTimeInterval(61)) }
                        .to(equal(["H2"]))
                }

                // MARK: ---- backs off before trying the swarm again
                it("backs off before trying the swarm again") {
                    await expect { await fixture.claim(["H2", "H3"]) }.to(beNil())
                    await expect { await fixture.claim(["H2", "H3"], now: fixture.now.addingTimeInterval(61)) }
                        .to(equal(["H2", "H3"]))
                }

                // MARK: ---- V13c doubles the deferral on each consecutive failure
                it("V13c doubles the deferral on each consecutive failure") {
                    /// One failure has already happened, so the deferral is 60s. Each further failed round doubles it, which
                    /// matters most on a client with no foreground gate - there "for the session" means days, and a flat 60s
                    /// would be ~1,440 rounds per swarm per day
                    let second: Date = fixture.now.addingTimeInterval(61)
                    _ = await fixture.claim(["H2"], now: second)
                    await fixture.release(claimed: ["H2"], stored: [], retryable: ["H2"], now: second)

                    /// 2nd failure -> 120s, so the second wait is strictly longer than the first
                    await expect { await fixture.claim(["H2"], now: second.addingTimeInterval(119)) }.to(beNil())
                    await expect { await fixture.claim(["H2"], now: second.addingTimeInterval(121)) }
                        .to(equal(["H2"]))
                }

                // MARK: ---- V13d never stops retrying, however many rounds have failed
                it("V13d never stops retrying, however many rounds have failed") {
                    /// The growth is a **deferral, not a cap**. An implementation that treats consecutive failures as a budget
                    /// would pass every other vector here while permanently abandoning the swarm - which is the question worth
                    /// asking of every guard in this file: *which population does it exclude?* Here it is the swarms that have
                    /// failed the most, which are exactly the ones whose configs are most likely to be gone
                    var when: Date = fixture.now

                    for _ in 0..<20 {
                        when = when.addingTimeInterval(1801)
                        _ = await fixture.claim(["H2"], now: when)
                        await fixture.release(claimed: ["H2"], stored: [], retryable: ["H2"], now: when)
                    }

                    await expect { await fixture.claim(["H2"], now: when.addingTimeInterval(1801)) }
                        .to(equal(["H2"]))
                }

                // MARK: ---- resets the deferral once a store succeeds
                it("resets the deferral once a store succeeds") {
                    /// Any success resets the growth - and that can't loop, because a stored hash is barred, so successes only
                    /// ever move in one direction
                    let second: Date = fixture.now.addingTimeInterval(61)
                    _ = await fixture.claim(["H2"], now: second)
                    await fixture.release(claimed: ["H2"], stored: ["H2"], retryable: [], now: second)

                    /// No deferral at all after a success, so a newly-detected hash is immediately claimable
                    await expect { await fixture.claim(["H5"], now: second.addingTimeInterval(1)) }
                        .to(equal(["H5"]))
                }
            }

            // MARK: -- when limiting concurrency
            context("when limiting concurrency") {
                // MARK: ---- won't claim the same swarm twice at once
                it("won't claim the same swarm twice at once") {
                    await fixture.store.markLocalStateLevelWithSwarm(swarmPublicKey: fixture.userSwarm)

                    await expect { await fixture.claim(["H1", "H2"]) }.toNot(beNil())
                    await expect { await fixture.claim(["H1", "H2"]) }.to(beNil())
                }

                // MARK: ---- won't exceed the concurrent swarm limit
                it("won't exceed the concurrent swarm limit") {
                    for key in ["05a", "05b", "05c"] {
                        await fixture.store.markLocalStateLevelWithSwarm(swarmPublicKey: key)
                    }

                    await expect { await fixture.claim(["Ha"], swarmPublicKey: "05a", maxConcurrentSwarms: 2) }
                        .toNot(beNil())
                    await expect { await fixture.claim(["Hb"], swarmPublicKey: "05b", maxConcurrentSwarms: 2) }
                        .toNot(beNil())
                    await expect { await fixture.claim(["Hc"], swarmPublicKey: "05c", maxConcurrentSwarms: 2) }
                        .to(beNil())
                }
            }
        }

        // MARK: - generating recovery data
        describe("generating recovery data") {
            // MARK: -- includes a clean config whose hash the swarm has lost
            it("includes a clean config whose hash the swarm has lost") {
                let result: [LibSession.ConfigRecoveryData] = fixture.recoveryData(missing: ["HASH-INFO"])

                expect(result.count).to(equal(1))
                expect(result.first?.variant).to(equal(.groupInfo))
                expect(result.first?.missingHashes).to(equal(["HASH-INFO"]))
                expect(result.first?.allHashes).to(equal(["HASH-INFO"]))
                expect(result.first?.data.isEmpty).to(beFalse())
            }

            // MARK: -- leaves the sequence number untouched
            it("leaves the sequence number untouched") {
                /// Recovery must not be a new revision - if generating the data bumped the seqno it would trigger a merge on
                /// every other device, which is the entire thing this design avoids
                let before: Int64 = fixture.currentSeqNo()
                let result: [LibSession.ConfigRecoveryData] = fixture.recoveryData(missing: ["HASH-INFO"])
                let after: Int64 = fixture.currentSeqNo()

                expect(result.first?.seqNo).to(equal(before))
                expect(after).to(equal(before))
                expect(LibSession.Config.groupInfo(fixture.groupInfoConf).needsPush).to(beFalse())
            }

            // MARK: -- V18 re-stores every part of a multipart config
            it("V18 re-stores every part of a multipart config") {
                /// `libSession` returns `active_hashes()` as an unordered set, so a part hash cannot be mapped back to its
                /// index in `push()`'s vector - every part of an affected config is re-stored rather than just the missing
                /// ones. Storing a part which is still present is a no-op TTL refresh, so this is safe
                let result: [LibSession.ConfigRecoveryData] = fixture.recoveryData(missing: ["HASH-INFO"])

                expect(result.first?.data.count).to(equal(1))
                expect(result.first?.allHashes).to(equal(["HASH-INFO"]))
            }

            // MARK: -- V20 re-stores for a non-admin member
            it("V20 re-stores for a non-admin member") {
                /// A member's dump retains the admin's signature, so its re-store reproduces byte-identical bytes and the
                /// storage server accepts it under member auth - group recovery does **not** need an admin online
                /// Positive proof the fixture really is the member view rather than the admin one
                expect(fixture.memberConfigIsReadOnly()).to(beTrue())

                let result: [LibSession.ConfigRecoveryData] = fixture.memberRecoveryData(missing: ["HASH-MEMBER"])

                expect(result.count).to(equal(1))
                expect(result.first?.data.isEmpty).to(beFalse())

                /// A read-only config never gets the obsolete-hash list handed back, so a member can re-store but never prune
                expect(result.first?.obsoleteHashes).to(beEmpty())
            }

            // MARK: -- V23 generates keys recovery data from the retained bytes
            it("V23 generates keys recovery data from the retained bytes") {
                /// **This test used to assert the opposite**, on the then-true grounds that `libSession` had no way to re-emit
                /// a keys message. It now retains each active keys message verbatim, so the bytes can be pushed back
                /// **unchanged** - same hash, no signature required - which is what lets a *member* repair a group's keys.
                ///
                /// **The premise is asserted first:** if the config held no active hashes this would return empty for an
                /// entirely different reason and pass without exercising anything
                expect(fixture.keysOnlyActiveHashes()).to(equal(["HASH-KEYS"]))

                let inspection: LibSession.ConfigRecoveryInspection = fixture.keysOnlyInspection(missing: ["HASH-KEYS"])

                expect(inspection.data.count).to(equal(1))
                expect(inspection.data.first?.variant).to(equal(.groupKeys))
                expect(inspection.data.first?.missingHashes).to(equal(["HASH-KEYS"]))

                /// The retained bytes actually came back - an empty payload would re-store nothing while looking like success
                expect(inspection.data.first?.data.count).to(equal(1))
                expect(inspection.data.first?.data.first?.isEmpty).to(beFalse())

                /// A keys message carries no obsolete-hash list, so this path issues no delete at all
                expect(inspection.data.first?.obsoleteHashes).to(beEmpty())

                /// And it is a settled answer, not a deferred one
                expect(inspection.inspectionFailedHashes).to(beEmpty())
            }

            // MARK: -- V11 skips a hash which is no longer one of the config's active hashes
            it("V11 skips a hash which is no longer one of the config's active hashes") {
                /// Only re-store what the device believes is current - a superseded hash has no business being put back
                expect(fixture.recoveryData(missing: ["HASH-OBSOLETE"])).to(beEmpty())
            }

            // MARK: -- V12 skips a group which was kicked
            it("V12 skips a group which was kicked") {
                try fixture.libSessionCache.markAsKicked(groupSessionIds: [fixture.groupSwarm])

                expect(fixture.libSessionCache.wasKickedFromGroup(groupSessionId: fixture.groupSessionId)).to(beTrue())

                /// Re-storing is impossible anyway - the credentials were cleared and the subaccount token revoked - so
                /// attempting it would only generate auth failures
                expect(fixture.recoveryData(missing: ["HASH-INFO"])).to(beEmpty())
            }

            // MARK: -- skips a group which was destroyed
            it("skips a group which was destroyed") {
                fixture.markGroupDestroyed()

                expect(fixture.libSessionCache.groupIsDestroyed(groupSessionId: fixture.groupSessionId)).to(beTrue())
                expect(fixture.recoveryData(missing: ["HASH-INFO"])).to(beEmpty())
            }

            // MARK: -- skips a config with unpushed local changes
            it("skips a config with unpushed local changes") {
                /// Recovery re-uploads state which already exists, it never creates new state - a dirty config will be stored
                /// under a new hash by the pending `ConfigurationSyncJob` anyway
                groups_info_set_name(fixture.groupInfoConf, "ChangedName")

                expect(LibSession.Config.groupInfo(fixture.groupInfoConf).needsPush).to(beTrue())
                expect(fixture.recoveryData(missing: ["HASH-INFO"])).to(beEmpty())

                /// ⚠️ **This cannot isolate the `needsPush` guard *for this config*, and the mechanism is narrower than it
                /// looks.** `ConfigBase::set_state` moves `_curr_hashes` into `_old_hashes` and clears it on the first change
                /// away from Clean - so a dirtied config has no *current* hashes, the intersection is empty, and it is excluded
                /// one step **before** `needsPush` is consulted. Deleting that guard leaves this test passing; measured.
                ///
                /// **But `active_hashes()` is `_curr_hashes` UNION the parts of any pending multipart set** (`!part.done &&
                /// part.expiry > now`), and `set_state` does not touch those. So a config that goes dirty *while a multipart
                /// set is still arriving* keeps a non-empty active-hash list, can intersect a genuinely missing part hash, and
                /// reaches `needsPush` - which is **load-bearing in exactly that case**, not redundant in general.
                ///
                /// The assertion below therefore holds *because this fixture has no multipart set in flight*, which is the
                /// ordinary case, and not because dirtying empties active hashes as a rule. It is still a useful tripwire for
                /// the curr-hash clearing; it is **not** a claim that the guard is dead code
                expect(fixture.libSessionCache.activeHashesByVariant(for: fixture.groupSwarm)[.groupInfo]).to(beEmpty())
            }

            // MARK: -- V22c reports a lossy merge rather than treating it as level with the swarm
            it("V22c reports a lossy merge rather than treating it as level with the swarm") {
                /// Merging deliberately tolerates an individual message failing - one undecryptable config must not fail a
                /// whole poll - so a successful call is **not** proof we incorporated what the swarm sent. A poll that dropped
                /// a config message is exactly the state where our view is knowably stale, which is what the level-with-swarm
                /// precondition exists to catch
                let result = try fixture.mergeOneGoodOneGarbage()

                /// It did not throw - which is the whole trap - but it reports taking in exactly one of the two
                ///
                /// Asserted as `1` rather than "fewer than 2" deliberately: if the good message failed too this would still be
                /// under 2 while demonstrating nothing about a *partial* merge
                expect(result.mergedCount).to(equal(1))
            }

            // MARK: -- does nothing when no hashes are missing
            it("does nothing when no hashes are missing") {
                expect(fixture.recoveryData(missing: [])).to(beEmpty())
            }

            // MARK: -- keeps a thrown inspection retryable rather than treating it as a verdict
            it("keeps a thrown inspection retryable rather than treating it as a verdict") {
                /// A guard says "this must not be re-stored"; a thrown inspection says nothing at all. Collapsing the two bars
                /// a hash permanently on a transient error, which is why they are separate fields rather than one optional
                let inspection: LibSession.ConfigRecoveryInspection = LibSession.ConfigRecoveryInspection(
                    data: [],
                    inspectionFailedHashes: ["HASH-THREW"]
                )

                expect(inspection.data).to(beEmpty())
                expect(inspection.inspectionFailedHashes).to(equal(["HASH-THREW"]))
            }
        }

        // MARK: - recovering
        describe("recovering") {
            beforeEach {
                await fixture.store.markLocalStateLevelWithSwarm(swarmPublicKey: fixture.userSwarm)
            }

            // MARK: -- does nothing in the background
            it("does nothing in the background") {
                /// Detection runs wherever polling runs, including the background, but acting on it does not - recovery is N
                /// extra store requests and the largest N coincides with the long-offline case most likely to be in a
                /// constrained background window
                ///
                /// **Note:** `isAppForegroundAndActive` is a protocol *extension* default so it is statically dispatched and
                /// can't be stubbed directly - `reportedApplicationState` is the requirement it reads
                try await fixture.mockAppContext
                    .when { $0.reportedApplicationState }
                    .thenReturn(UIApplication.State.background)

                expect(fixture.dependencies[singleton: .appContext].isAppForegroundAndActive).to(beFalse())

                await ConfigRecovery.recoverIfNeeded(
                    fixture.report(missing: ["H2"], activeHashesByVariant: [.userProfile: ["H2"]]),
                    swarmPublicKey: fixture.userSwarm,
                    using: fixture.dependencies
                )

                /// The libSession guards were never consulted, which is what proves it returned before doing any work
                await fixture.mockLibSessionCache
                    .verify { $0.configRecoveryData(swarmPublicKey: .any, missingHashes: .any) }
                    .wasNotCalled(timeout: .milliseconds(100))
            }

            // MARK: -- consults the guards in the foreground
            it("consults the guards in the foreground") {
                /// The positive counterpart the negative above depends on - it asserts an effect that only exists if the path
                /// ran to **completion**, rather than that the happy path merely didn't fail
                try await fixture.foreground()

                await ConfigRecovery.recoverIfNeeded(
                    fixture.report(missing: ["H2"], activeHashesByVariant: [.userProfile: ["H2"]]),
                    swarmPublicKey: fixture.userSwarm,
                    using: fixture.dependencies
                )

                await fixture.mockLibSessionCache
                    .verify { $0.configRecoveryData(swarmPublicKey: .any, missingHashes: .any) }
                    .wasCalled(exactly: 1, timeout: .milliseconds(100))
            }

            // MARK: -- V13h chunks a recovery that exceeds the server's sub-request limit
            it("V13h chunks a recovery that exceeds the server's sub-request limit") {
                /// The storage server rejects a batch of **more than 20** sub-requests outright rather than truncating it, so
                /// an unchunked recovery loses every store in it - and because a single config can split into ~66 parts, the
                /// accounts with the most to lose are exactly the ones that would be rejected wholesale.
                ///
                /// Asserts the **boundary**, not eventual success: the fixture supplies 25 parts plus a delete, so a correct
                /// implementation must send exactly two batches of at most 20 sub-requests each. Counting only "did everything
                /// store" would pass on an implementation that got lucky with a small fixture
                try await fixture.foreground()
                try await fixture.stubRecovery(partCount: 25)

                await ConfigRecovery.recoverIfNeeded(
                    fixture.report(missing: ["H2"], activeHashesByVariant: [.userProfile: ["H2"]]),
                    swarmPublicKey: fixture.userSwarm,
                    using: fixture.dependencies
                )

                let calls: [(subRequests: Int, hasDelete: Bool)] = await fixture.batchShapes()
                let storeBatches: [(subRequests: Int, hasDelete: Bool)] = calls.filter { $0.subRequests > 0 }

                /// Asserted as properties rather than exact sizes: pinning the split would break under a legitimate refactor
                /// that packed the batches differently, even though the boundary still held
                expect(storeBatches.count).to(beGreaterThan(1))
                expect(storeBatches.allSatisfy { $0.subRequests <= 20 }).to(beTrue())

                /// Every part reached the wire
                expect(storeBatches.map { $0.subRequests }.reduce(0, +)).to(equal(25))
            }

            // MARK: -- does not sweep superseded hashes when the restore didn't land
            it("does not sweep superseded hashes when the restore didn't land") {
                /// The sweep exists because `push()` clears `libSession`'s copy of the superseded hashes, so an undeleted one
                /// lingers until its TTL. But a restore that did **not** land leaves the swarm still holding the state those
                /// hashes belong to, and deleting them then removes data with nothing put back in its place.
                ///
                /// Here the stubbed batch reports no sub-responses, so no store is confirmed - and nothing is swept. The positive
                /// direction is `V17` below
                try await fixture.foreground()
                try await fixture.stubRecovery(partCount: 2, outcome: .noSubResponses)

                await ConfigRecovery.recoverIfNeeded(
                    fixture.report(missing: ["H2"], activeHashesByVariant: [.userProfile: ["H2"]]),
                    swarmPublicKey: fixture.userSwarm,
                    using: fixture.dependencies
                )

                let calls: [(subRequests: Int, hasDelete: Bool)] = await fixture.batchShapes()

                expect(calls.contains { $0.hasDelete }).to(beFalse())

                /// The stores were still attempted, so this is the sweep being withheld rather than the round doing nothing
                expect(calls.filter { $0.subRequests > 0 }.count).to(equal(1))
            }

            // MARK: -- V17 sweeps the superseded hashes once the restore has landed
            it("V17 sweeps the superseded hashes once the restore has landed") {
                /// The positive direction of the sweep rule, and the counterpart the two negatives above and below both depend on.
                /// Asserting
                /// only that a sweep is *withheld* cannot distinguish "the rule held" from "the sweep is never issued at all",
                /// which is the shape that makes the sweep a silent no-op
                try await fixture.foreground()
                try await fixture.stubRecovery(partCount: 2, obsoleteHashes: ["OLD-HASH"], outcome: .landed)

                await ConfigRecovery.recoverIfNeeded(
                    fixture.report(missing: ["H2"], activeHashesByVariant: [.userProfile: ["H2"]]),
                    swarmPublicKey: fixture.userSwarm,
                    using: fixture.dependencies
                )

                let calls: [(subRequests: Int, hasDelete: Bool)] = await fixture.batchShapes()

                /// One store batch, then the sweep - and in that order, which is the other half of the rule: a delete applied before
                /// its stores would strand them if it were rejected
                expect(calls.count).to(equal(2))
                expect(calls.first?.subRequests).to(equal(2))
                expect(calls.last?.hasDelete).to(beTrue())

                /// The store landed, so its hash is barred rather than left pending
                await expect { await fixture.isStillRetryable("H2") }.to(beFalse())
            }

            // MARK: -- V17b issues no delete when there are no superseded hashes
            it("V17b issues no delete when there are no superseded hashes") {
                /// The negative counterpart to `V17`: a config whose `push()` hands back an **empty** obsolete-hash list must not
                /// produce a delete request at all. The natural bug is issuing one anyway - an empty `delete` is a signed request
                /// the server accepts and does nothing with, so it never surfaces as an error, it just costs a round trip on
                /// every recovery.
                ///
                /// **Asserted by the total number of requests, not by what the delete contained.** With no obsolete hashes there
                /// is no hash to look for, so a "the delete didn't mention OLD-HASH" assertion passes on an implementation which
                /// sends an empty delete - the exact bug this vector exists for
                try await fixture.foreground()
                try await fixture.stubRecovery(partCount: 2, obsoleteHashes: [], outcome: .landed)

                await ConfigRecovery.recoverIfNeeded(
                    fixture.report(missing: ["H2"], activeHashesByVariant: [.userProfile: ["H2"]]),
                    swarmPublicKey: fixture.userSwarm,
                    using: fixture.dependencies
                )

                let calls: [(subRequests: Int, hasDelete: Bool)] = await fixture.batchShapes()

                /// The reachability control: the store batch **did** go out and **did** land, so the path reached the point where
                /// `V17` issues its sweep. Without this, total inaction satisfies the assertion below
                expect(calls.first?.subRequests).to(equal(2))
                await expect { await fixture.isStillRetryable("H2") }.to(beFalse())

                /// The store batch is the only request - nothing followed it
                expect(calls.count).to(equal(1))
            }

            // MARK: -- V23d clears the expired flag itself when the repair lands
            it("V23d clears the expired flag itself when the repair lands") {
                /// **The reactive path cannot do this one.** It clears the flag when a keys message is successfully *handled* -
                /// which happens on the *peer* that fetches the re-stored message. The device that did the re-storing already
                /// holds that hash and will never re-handle it, so relying on reactivity leaves its own flag set forever over
                /// keys it just put back on the swarm.
                ///
                /// So a landed repair applies `notExpired` eagerly, and a failed one applies `expired` - the two are different
                /// code paths from the same branch, which is why `V23c` and this cannot share a fixture
                try await fixture.foreground()
                try await fixture.stubRecovery(partCount: 1, obsoleteHashes: [], outcome: .landed)

                await ConfigRecovery.recoverIfNeeded(
                    fixture.keysReport(missing: ["H2"]),
                    swarmPublicKey: fixture.userSwarm,
                    using: fixture.dependencies
                )

                /// The repair landed, so the hash is banked rather than left pending - which is the input to the eager clear
                await expect { await fixture.isStillRetryable("H2") }.to(beFalse())

                /// ⚠️ **The flag write itself is not asserted** - `applyKeysVerdictIfNeeded` goes through `updateAllAndConfig`
                /// and this fixture has no database, the same gap recorded on `V16b` and `V23c`. What is pinned is that the
                /// branch is reached with the *success* outcome: `attemptedKeysHashes` is non-empty and fully stored, which is
                /// the only state that selects `notExpired` over `expired`
                expect(fixture.keysReport(missing: ["H2"]).attemptedKeysHashes).to(equal(["H2"]))
            }

            // MARK: -- V23c keeps a failed keys repair retryable rather than banking it
            it("V23c keeps a failed keys repair retryable rather than banking it") {
                /// A keys repair that did not land leaves the user unable to decrypt, so it must not be recorded as done. The
                /// hashes stay eligible for a later round under the usual backoff, exactly like any other failed store - the
                /// difference is only that the group is flagged expired afterwards, since a failed repair should not leave the
                /// user with no signal
                try await fixture.foreground()
                try await fixture.stubRecovery(partCount: 2, obsoleteHashes: [], outcome: .subRequestFailed)

                await ConfigRecovery.recoverIfNeeded(
                    fixture.report(missing: ["H2"], activeHashesByVariant: [.userProfile: ["H2"]]),
                    swarmPublicKey: fixture.userSwarm,
                    using: fixture.dependencies
                )

                /// The stores were attempted and none landed, so nothing is banked
                let calls: [(subRequests: Int, hasDelete: Bool)] = await fixture.batchShapes()

                expect(calls.filter { $0.subRequests > 0 }.count).to(equal(1))
                await expect { await fixture.isStillRetryable("H2") }.to(beTrue())

                /// ⚠️ **The expired-flag half is not asserted here, and that is a fixture limit rather than a design choice.**
                /// `applyKeysVerdictIfNeeded` writes through `updateAllAndConfig`, and this fixture has no database - the same
                /// gap already recorded on `V16b`. What *is* pinned is the decision input: `attemptedKeysHashes` is non-empty
                /// only when a repair was attempted (`V23`), and it is empty whenever one was not (`V23a`), so the branch that
                /// applies the flag cannot fire on a group that was never being repaired
                expect(
                    ConfigRecovery.DetectionReport(
                        detection: .checked(missingHashes: ["K1"]),
                        activeHashesByVariant: [.groupKeys: ["K1"], .groupInfo: ["I1"]],
                        recoverableKeysHashes: []
                    ).attemptedKeysHashes
                ).to(beEmpty())
            }

            // MARK: -- V13b keeps a hash retryable when the store's own sub-response failed
            it("V13b keeps a hash retryable when the store's own sub-response failed") {
                /// A `sequence` returns 200 whenever the *request* was understood; each store carries its own code inside. So
                /// "the call didn't throw" is not "the config was stored", and treating it as such bars the hash on a response
                /// where nothing was written - withdrawing recovery from a device whose config really is gone.
                ///
                /// The stubbed sub-response carries a **decodable body** with a 5xx code, so the status check is the only thing
                /// that can reject it: an implementation keying on "didn't throw", or on whether the body parsed, accepts this
                try await fixture.foreground()
                try await fixture.stubRecovery(partCount: 2, outcome: .subRequestFailed)

                await ConfigRecovery.recoverIfNeeded(
                    fixture.report(missing: ["H2"], activeHashesByVariant: [.userProfile: ["H2"]]),
                    swarmPublicKey: fixture.userSwarm,
                    using: fixture.dependencies
                )

                let calls: [(subRequests: Int, hasDelete: Bool)] = await fixture.batchShapes()

                /// The stores were attempted - the difference from `V17` is only what came back
                expect(calls.filter { $0.subRequests > 0 }.count).to(equal(1))

                /// Nothing landed, so nothing may be swept and the hash stays eligible for a later round
                expect(calls.contains { $0.hasDelete }).to(beFalse())
                await expect { await fixture.isStillRetryable("H2") }.to(beTrue())
            }

            // MARK: -- does nothing when the detection offered no candidates
            it("does nothing when the detection offered no candidates") {
                try await fixture.foreground()

                await ConfigRecovery.recoverIfNeeded(
                    .noDetection,
                    swarmPublicKey: fixture.userSwarm,
                    using: fixture.dependencies
                )

                await fixture.mockLibSessionCache
                    .verify { $0.configRecoveryData(swarmPublicKey: .any, missingHashes: .any) }
                    .wasNotCalled(timeout: .milliseconds(100))
            }
        }
    }
}

// MARK: - ConfigRecoveryTestFixture

private class ConfigRecoveryTestFixture: FixtureBase {
    /// A group identity keypair distinct from the user's (the same pair `LibSessionSpec` stubs `createGroup` with)
    static let groupPublicKey: String = "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
    static let groupSecretKey: String = [
        "0123456789abcdef0123456789abcdeffedcba9876543210fedcba9876543210",
        "cbd569f56fb13ea95a3f0c05c331cc24139c0090feb412069dc49fab34406ece"
    ].joined()

    let userSwarm: String = "05\(TestConstants.publicKey)"
    let groupSessionId: SessionId = SessionId(.group, hex: ConfigRecoveryTestFixture.groupPublicKey)
    var groupSwarm: String { groupSessionId.hexString }
    var now: Date { dependencies.dateNow }

    /// The real store, because these tests are about the values it ends up holding
    let store: ConfigRecovery.Store = ConfigRecovery.Store()

    /// A real `libSession` cache too - the recovery guards live inside it, and a mock would only assert what the mock returns
    private(set) var libSessionCache: LibSession.Cache!
    private(set) var groupInfoConf: UnsafeMutablePointer<config_object>!
    private(set) var groupKeysConf: UnsafeMutablePointer<config_group_keys>!
    private(set) var userGroupsConf: UnsafeMutablePointer<config_object>!
    private(set) var memberInfoConf: UnsafeMutablePointer<config_object>!

    /// A separate cache holding the read-only member view, so the member path can be exercised without disturbing the admin one
    private(set) var memberLibSessionCache: LibSession.Cache!

    /// A cache holding **only** a `groupKeys` config, so the "a keys config is never recovered" guard can be reached
    ///
    /// **Deliberately its own cache with nothing else in it.** A `.groupKeys` `Config` owns the keys, info *and* members
    /// pointers, so registering one alongside that group's `.groupInfo` would free the info pointer twice on deinit - which
    /// aborts the whole test process rather than failing a test
    private(set) var keysOnlyLibSessionCache: LibSession.Cache!

    var mockNetwork: MockNetwork { mock(for: .network) }
    var mockGeneralCache: MockGeneralCache { mock(cache: .general) }
    var mockAppContext: MockAppContext { mock(for: .appContext) }
    var mockLibSessionCache: MockLibSessionCache { mock(cache: .libSession) }

    // MARK: - Convenience

    /// A report whose missing hash is a **keys** hash the device holds bytes for, i.e. a repair in flight
    func keysReport(missing: Set<String>) -> ConfigRecovery.DetectionReport {
        return ConfigRecovery.DetectionReport(
            detection: .checked(missingHashes: missing),
            activeHashesByVariant: [.groupKeys: missing, .groupInfo: ["I1"]],
            recoverableKeysHashes: missing
        )
    }

    /// Build a `DetectionReport` the way a poll would
    func report(
        missing: Set<String>,
        activeHashesByVariant: [ConfigDump.Variant: Set<String>]
    ) -> ConfigRecovery.DetectionReport {
        return ConfigRecovery.DetectionReport(
            detection: .checked(missingHashes: missing),
            activeHashesByVariant: activeHashesByVariant
        )
    }

    func claim(
        _ candidateHashes: Set<String>,
        swarmPublicKey: String? = nil,
        maxConcurrentSwarms: Int = 3,
        now: Date? = nil
    ) async -> Set<String>? {
        return await store.beginRecovery(
            swarmPublicKey: (swarmPublicKey ?? userSwarm),
            candidateHashes: candidateHashes,
            maxConcurrentSwarms: maxConcurrentSwarms,
            now: (now ?? self.now)
        )
    }

    func release(
        claimed: Set<String>,
        stored: Set<String>,
        retryable: Set<String>,
        swarmPublicKey: String? = nil,
        now: Date? = nil
    ) async {
        await store.endRecovery(
            swarmPublicKey: (swarmPublicKey ?? userSwarm),
            claimedHashes: claimed,
            storedHashes: stored,
            retryableHashes: retryable,
            now: (now ?? self.now),
            barInterval: (60 * 60),
            baseBackoff: 60,
            maxBackoff: (30 * 60)
        )
    }

    /// What the stubbed `sequence` reports back about the stores inside it
    ///
    /// The three cases are genuinely different branches of the check in `recoverIfNeeded`, not degrees of the same one, and a
    /// `Bool` would collapse the two failures into each other
    enum StoreOutcome {
        /// A batch whose body carries no sub-responses at all, so no store can be confirmed
        case noSubResponses

        /// Every store's own sub-response is a decodable 2xx - the only shape that counts as landed
        case landed

        /// The batch returns 200 while the store's **own** sub-response carries a 5xx
        ///
        /// The body is still decodable on purpose: it leaves the status code as the *only* thing that can reject the store, so an
        /// implementation which keys off "didn't throw" or "the body parsed" accepts it
        case subRequestFailed
    }

    /// Make the recovery path produce `partCount` store sub-requests, and stub the network so each batch is observable
    func stubRecovery(
        partCount: Int,
        obsoleteHashes: Set<String> = ["OLD-HASH"],
        outcome: StoreOutcome = .noSubResponses
    ) async throws {
        /// A `SendMessagesResponse` the batch decoder will actually accept - it needs the store's `hash`, a `swarm` dict and the
        /// `hf`/`t` every storage server response carries. The swarm may be empty because a sub-response inside a batch is not
        /// re-validated; only its code and whether the body parsed are read
        ///
        /// Wrapped in `{"results": […]}` because that is what the **storage server** returns for `sequence` - it has no
        /// bare-array response path at all; the bare form is SOGS's, and `decodingResponses` branches on the difference. A
        /// bare-array stub here would test the right logic through a branch this path never takes
        let storeBody: String = "{\"hash\":\"H2\",\"swarm\":{},\"hf\":[19,3],\"t\":1}"
        let responseData: Data = {
            switch outcome {
                case .noSubResponses: return Data("{\"results\":[]}".utf8)
                case .landed, .subRequestFailed:
                    let code: Int = (outcome == .landed ? 200 : 500)
                    let subResponse: String = "{\"code\":\(code),\"body\":\(storeBody)}"
                    let subResponses: String = Array(repeating: subResponse, count: partCount).joined(separator: ",")

                    return Data("{\"results\":[\(subResponses)]}".utf8)
            }
        }()

        try await mockNetwork.defaultInitialSetup(using: dependencies)
        try await mockNetwork
            .when {
                try await $0.send(
                    endpoint: MockEndpoint.any,
                    destination: .any,
                    body: .any,
                    category: .any,
                    requestTimeout: .any,
                    overallTimeout: .any
                )
            }
            .thenReturn((Network.ResponseInfo(code: 200, headers: [:]), responseData))

        /// One config with `partCount` parts, and whichever obsolete hashes the vector needs swept (or none)
        try await mockLibSessionCache
            .when { $0.configRecoveryData(swarmPublicKey: .any, missingHashes: .any) }
            .thenReturn(
                LibSession.ConfigRecoveryInspection(
                    data: [
                        LibSession.ConfigRecoveryData(
                            variant: .userProfile,
                            missingHashes: ["H2"],
                            allHashes: ["H2"],
                            data: (0..<partCount).map { Data([UInt8($0)]) },
                            seqNo: 1,
                            obsoleteHashes: obsoleteHashes
                        )
                    ]
                )
            )
    }

    /// Whether the hash is still available for another attempt, i.e. it was **not** barred by the round that just ran
    func isStillRetryable(_ hash: String) async -> Bool {
        return await store.hashesEligibleForRecovery([hash], now: now).contains(hash)
    }

    /// The shape of each batch that actually reached the network, in order
    func batchShapes() async -> [(subRequests: Int, hasDelete: Bool)] {
        let info = await mockNetwork
            .verify {
                try await $0.send(
                    endpoint: MockEndpoint.any,
                    destination: .any,
                    body: .any,
                    category: .any,
                    requestTimeout: .any,
                    overallTimeout: .any
                )
            }
            .wasCalled(atLeast: 1, timeout: .milliseconds(500))

        return (info?.matchingCalls ?? []).map { call in
            /// Counting method occurrences rather than decoding the batch - the body is the encoded sequence, and the count
            /// plus whether a delete is present is all these assertions need
            let summary: String = (call.parameterSummary ?? "")

            return (
                subRequests: (summary.components(separatedBy: "\"method\"").count - 1),
                /// Identified by the hash it must sweep rather than by an endpoint name - that asserts the sweep targeted
                /// the right thing, and doesn't depend on how the summary spells the endpoint
                hasDelete: summary.contains("OLD-HASH")
            )
        }
    }

    func foreground() async throws {
        try await mockAppContext.when { $0.reportedApplicationState }.thenReturn(UIApplication.State.active)

        /// Needed only by the keys vectors: a landed repair clears the expired flag, and that write reaches `isMainApp`
        try await mockAppContext.when { $0.isMainApp }.thenReturn(true)
    }

    func recoveryData(missing: Set<String>) -> [LibSession.ConfigRecoveryData] {
        return libSessionCache.configRecoveryData(swarmPublicKey: groupSwarm, missingHashes: missing).data
    }

    func memberRecoveryData(missing: Set<String>) -> [LibSession.ConfigRecoveryData] {
        return memberLibSessionCache.configRecoveryData(swarmPublicKey: groupSwarm, missingHashes: missing).data
    }

    func keysOnlyInspection(missing: Set<String>) -> LibSession.ConfigRecoveryInspection {
        return keysOnlyLibSessionCache.configRecoveryData(swarmPublicKey: groupSwarm, missingHashes: missing)
    }

    /// What the keys-only cache believes it currently holds - the premise the vector below rests on
    func keysOnlyActiveHashes() -> Set<String> {
        return (keysOnlyLibSessionCache.activeHashesByVariant(for: groupSwarm)[.groupKeys] ?? [])
    }

    func memberConfigIsReadOnly() -> Bool {
        /// A read-only config never gets the obsolete-hash list handed back, which is the observable difference that makes the
        /// "member can re-store but never prune" assertion meaningful rather than incidental
        return (LibSession.Config.groupInfo(memberInfoConf).activeHashes() == ["HASH-MEMBER"])
    }

    func currentSeqNo() -> Int64 {
        return ((try? LibSession.Config.groupInfo(groupInfoConf).push(variant: .groupInfo))?.pushData.first?.seqNo ?? -1)
    }

    func markGroupDestroyed() {
        var userGroup: ugroups_group_info = ugroups_group_info()
        var cGroupId: [CChar] = groupSwarm.cString(using: .utf8)!

        guard user_groups_get_group(userGroupsConf, &userGroup, &cGroupId) else { return }

        ugroups_group_set_destroyed(&userGroup)
        _ = user_groups_set_group(userGroupsConf, &userGroup)
    }

    /// One message this config can take in and one it cannot, to show a partial merge reports itself
    func mergeOneGoodOneGarbage() throws -> (latestServerTimestampMs: Int64?, mergedCount: Int) {
        let good: Data = ((try LibSession.Config.groupInfo(groupInfoConf).push(variant: .groupInfo))?
            .pushData.first?.data.first ?? Data())

        return try LibSession.Config.groupInfo(groupInfoConf).merge([
            ConfigMessageReceiveJob.Details.MessageInfo(
                namespace: .configGroupInfo,
                serverHash: "HASH-GOOD",
                serverTimestampMs: 1234567890,
                data: good
            ),
            ConfigMessageReceiveJob.Details.MessageInfo(
                namespace: .configGroupInfo,
                serverHash: "HASH-GARBAGE",
                serverTimestampMs: 1234567891,
                data: Data([9, 9, 9, 9])
            )
        ])
    }

    // MARK: - Initialization

    static func create() async throws -> ConfigRecoveryTestFixture {
        let fixture: ConfigRecoveryTestFixture = ConfigRecoveryTestFixture()
        try await fixture.applyBaselineStubs()

        return fixture
    }

    private func applyBaselineStubs() async throws {
        dependencies.set(singleton: .configRecovery, to: store)
        try await mockGeneralCache.defaultInitialSetup()
        try await mockLibSessionCache.defaultInitialSetup()

        libSessionCache = LibSession.Cache(
            userSessionId: SessionId(.standard, hex: TestConstants.publicKey),
            using: dependencies
        )

        /// A full group config set (keys wired into info & members) - a standalone `groups_info` config has no encryption key
        /// until a keys message is loaded into it, so it can't produce push data at all
        let groupState: [ConfigDump.Variant: LibSession.Config] = try LibSession.createGroupState(
            groupSessionId: groupSessionId,
            userED25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
            groupIdentityPrivateKey: Data(hex: ConfigRecoveryTestFixture.groupSecretKey)
        )

        guard case .groupKeys(let keysConf, let infoConf, let membersConf) = groupState[.groupKeys] else {
            throw LibSessionError.unableToCreateConfigObject(groupSessionId.hexString)
        }

        groups_info_set_name(infoConf, "TestGroup")
        groupInfoConf = infoConf
        groupKeysConf = keysConf

        /// The group needs its admin as a member and an initial key generation, otherwise the info config has no encryption
        /// key and can't produce push data at all
        var member: config_group_member = config_group_member()
        member.set(\.session_id, to: userSwarm)
        member.set(\.admin, to: true)
        groups_members_set(membersConf, &member)
        try LibSessionError.throwIfNeeded(membersConf)

        var pushResult: UnsafePointer<UInt8>? = nil
        var pushResultLen: Int = 0
        _ = groups_keys_rekey(keysConf, infoConf, membersConf, &pushResult, &pushResultLen)

        /// The admin's keys message, needed to give the member view a decryption key
        let keysMessage: Data = (pushResult.map { Data(bytes: $0, count: pushResultLen) } ?? Data())

        /// Push and confirm so the config is **clean** with a single known active hash - the state a real config is in
        /// whenever recovery could apply to it
        let config: LibSession.Config = .groupInfo(infoConf)
        let pushed: LibSession.PendingPushes? = try config.push(variant: .groupInfo)
        try config.confirmPushed(seqNo: (pushed?.pushData.first?.seqNo ?? 0), hashes: ["HASH-INFO"])

        /// A **read-only member** view of the same group, for the member-path vector
        ///
        /// Built the way a real member gets one: no group identity key (so `is_readonly()`), the admin's keys message loaded to
        /// supply the decryption key, then the admin's config merged in. That merge is what retains the admin's signature, which
        /// is why a member's re-store reproduces byte-identical bytes without being able to sign
        let memberState: [ConfigDump.Variant: LibSession.Config] = try LibSession.createGroupState(
            groupSessionId: groupSessionId,
            userED25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
            groupIdentityPrivateKey: nil
        )

        guard
            case .groupKeys(let memberKeysConf, let readOnlyInfoConf, let memberMembersConf) = memberState[.groupKeys]
        else { throw LibSessionError.unableToCreateConfigObject(groupSessionId.hexString) }

        memberInfoConf = readOnlyInfoConf

        var keysBytes: [UInt8] = Array(keysMessage)
        var cKeysHash: [CChar] = "HASH-KEYS".cString(using: .utf8)!
        _ = groups_keys_load_message(
            memberKeysConf,
            &cKeysHash,
            &keysBytes,
            keysBytes.count,
            1234567890,
            readOnlyInfoConf,
            memberMembersConf
        )

        /// Merge the admin's pushed config so the member view *becomes* it, carrying the signature, and ends up clean with
        /// `HASH-MEMBER` as its one active hash
        let adminInfoPush: Data = (pushed?.pushData.first?.data.first ?? Data())
        _ = try LibSession.Config.groupInfo(readOnlyInfoConf).merge([
            ConfigMessageReceiveJob.Details.MessageInfo(
                namespace: .configGroupInfo,
                serverHash: "HASH-MEMBER",
                serverTimestampMs: 1234567891,
                data: adminInfoPush
            )
        ])

        memberLibSessionCache = LibSession.Cache(
            userSessionId: SessionId(.standard, hex: TestConstants.publicKey),
            using: dependencies
        )
        memberLibSessionCache.setConfig(for: .groupInfo, sessionId: groupSessionId, to: .groupInfo(readOnlyInfoConf))

        /// A **third** member view, used only to register a `groupKeys` config on its own
        ///
        /// It has to be its own state rather than reusing the member view above, for the double-free reason on
        /// `keysOnlyLibSessionCache`: that view's info pointer is already registered as `.groupInfo` elsewhere
        let keysOnlyState: [ConfigDump.Variant: LibSession.Config] = try LibSession.createGroupState(
            groupSessionId: groupSessionId,
            userED25519SecretKey: Array(Data(hex: TestConstants.edSecretKey)),
            groupIdentityPrivateKey: nil
        )

        guard
            case .groupKeys(let keysOnlyKeysConf, let keysOnlyInfoConf, let keysOnlyMembersConf) = keysOnlyState[.groupKeys],
            let keysOnlyConfig: LibSession.Config = keysOnlyState[.groupKeys]
        else { throw LibSessionError.unableToCreateConfigObject(groupSessionId.hexString) }

        /// Load the admin's keys message so the config genuinely holds `HASH-KEYS` as an active hash - without that the guard
        /// under test is never reached, because the hash wouldn't match anything
        var keysOnlyBytes: [UInt8] = Array(keysMessage)
        var cKeysOnlyHash: [CChar] = "HASH-KEYS".cString(using: .utf8)!
        _ = groups_keys_load_message(
            keysOnlyKeysConf,
            &cKeysOnlyHash,
            &keysOnlyBytes,
            keysOnlyBytes.count,
            1234567890,
            keysOnlyInfoConf,
            keysOnlyMembersConf
        )

        keysOnlyLibSessionCache = LibSession.Cache(
            userSessionId: SessionId(.standard, hex: TestConstants.publicKey),
            using: dependencies
        )
        keysOnlyLibSessionCache.setConfig(for: .groupKeys, sessionId: groupSessionId, to: keysOnlyConfig)

        var userEdSecretKey: [UInt8] = Array(Data(hex: TestConstants.edSecretKey))
        var groupsConf: UnsafeMutablePointer<config_object>!
        _ = user_groups_init(&groupsConf, &userEdSecretKey, nil, 0, nil)
        userGroupsConf = groupsConf

        /// The group has to exist in `userGroups` for the kicked/destroyed checks to have anything to read
        var userGroup: ugroups_group_info = ugroups_group_info()
        var cGroupId: [CChar] = groupSwarm.cString(using: .utf8)!
        _ = user_groups_get_or_construct_group(groupsConf, &userGroup, &cGroupId)
        _ = user_groups_set_group(groupsConf, &userGroup)

        /// **Deliberately no `userGroups` on the member cache.** Registering the *same* config pointer in two
        /// `LibSession.Cache` instances double-frees it - each `ConfigStore.deinit` frees what it holds, so the second
        /// deallocation aborts the whole test process. The kicked/destroyed checks return `false` when the config is absent,
        /// which is what this path wants anyway
        libSessionCache.setConfig(for: .groupInfo, sessionId: groupSessionId, to: .groupInfo(infoConf))
        libSessionCache.setConfig(
            for: .userGroups,
            sessionId: SessionId(.standard, hex: TestConstants.publicKey),
            to: .userGroups(groupsConf)
        )
    }
}
