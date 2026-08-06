// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionNetworkingKit
import SessionUtilitiesKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("ConfigRecovery", defaultLevel: .info)
}

// MARK: - ConfigRecovery

/// Puts config messages back on their swarm after they have expired from it
///
/// Config messages have a 30 day TTL which is refreshed whenever a device polls, so a user who goes quiet for 30 days has
/// their synced account state swept and restoring from seed gives them an empty account. Any device which is still logged in
/// holds a good config locally, though, and the TTL-extension response tells us when the swarm no longer has it - so it can
/// put it back.
///
/// This is safe because `libSession`'s config encryption is deterministic and the storage server derives a message's hash from
/// its ciphertext, so re-storing an unchanged config produces **the same message hash it had before**. It isn't a new message
/// competing with existing state, it's the same message going back where it was: no new seqno, no merge, no fork, and nothing
/// can be overwritten. Two devices recovering at once compute the same hash and the second is a no-op.
public enum ConfigRecovery {
    /// What a conclusive detection said about a group's keys config
    ///
    /// The keys config is the sole determinant of whether a group is "expired": it's the only one of the three whose
    /// absence is both unambiguous and unrepairable by the device that noticed. `GroupInfo`/`GroupMembers` absence drives
    /// recovery instead, and must not move this flag
    public enum KeysVerdict: Equatable {
        /// Every keys hash we asked about is gone, so only an admin rekey can repair the group
        case expired

        /// At least one keys hash survives
        case notExpired

        /// This detection says nothing about the group - either it wasn't conclusive, or the device holds no keys hashes
        /// at all, in which case the existing "no config messages in the first poll" check is the authority
        case noVerdict
    }

    /// What one poll's expiry detection found, handed straight from the poll to the two things that act on it
    ///
    /// Deliberately a **parameter rather than cache state**. Storing a detection and consuming it later allows a verdict to be
    /// picked up by the wrong poll, or silently dropped when nothing consumes it - and the accumulation bought nothing, because
    /// detection is repeated on every poll: a hash that is still missing is reported again next time. Android passes its report
    /// the same way (`Poller.kt` → `onUserConfigsChecked(auth, report:)`), so this is the shared shape rather than an iOS one
    public struct DetectionReport {
        /// What this detection said about the group's keys config, if anything
        public let keysVerdict: KeysVerdict

        /// Missing hashes which are actually candidates for a re-store
        ///
        /// Keys hashes are excluded here rather than downstream: `libSession` has no API to re-emit a keys message it already
        /// holds, so they can be *detected* as expired but never recovered
        public let recoverableMissingHashes: Set<String>

        /// A detection that says nothing - the response couldn't answer, or nothing answered at all
        ///
        /// **Note:** Deliberately not called `none`; that shadows `Optional.none` at any use site where the contextual type is
        /// an optional, which is a silent mis-resolution rather than an error
        public static let noDetection: DetectionReport = DetectionReport(
            keysVerdict: .noVerdict,
            recoverableMissingHashes: []
        )

        public init(keysVerdict: KeysVerdict, recoverableMissingHashes: Set<String>) {
            self.keysVerdict = keysVerdict
            self.recoverableMissingHashes = recoverableMissingHashes
        }

        public init(
            detection: Network.StorageServer.ConfigExpiryDetection,
            activeHashesByVariant: [ConfigDump.Variant: Set<String>]
        ) {
            /// Neither `unavailable` nor `inconclusive` may mark anything missing, and neither may move the expired flag -
            /// the former means the response couldn't answer the question, the latter that nothing answered at all
            guard case .checked(let missingHashes) = detection else {
                self = .noDetection
                return
            }

            let recoverableHashes: Set<String> = activeHashesByVariant
                .filter { variant, _ in variant != .groupKeys }
                .reduce(into: []) { result, next in result.formUnion(next.value) }

            self.keysVerdict = DetectionReport.keysVerdict(
                missingHashes: missingHashes,
                keysHashes: (activeHashesByVariant[.groupKeys] ?? [])
            )
            self.recoverableMissingHashes = missingHashes.intersection(recoverableHashes)
        }

        /// The group is expired **iff every** keys hash the device asked about is MISSING - a single surviving keys hash
        /// clears it
        ///
        /// A device legitimately holds several keys hashes at once (a generation is one rekey message plus N
        /// `key_supplement` messages), so "all" and "any" genuinely differ here
        private static func keysVerdict(
            missingHashes: Set<String>,
            keysHashes: Set<String>
        ) -> KeysVerdict {
            /// With no keys hashes there was nothing to ask about, so this detection says nothing about the group - the
            /// existing "no config messages in the first poll" check is what covers that case
            guard !keysHashes.isEmpty else { return .noVerdict }

            return (keysHashes.isSubset(of: missingHashes) ? .expired : .notExpired)
        }
    }

    /// The most swarms we will recover concurrently
    ///
    /// Recovery is not latency sensitive and the worst case (a long-offline device with every config expired) is also the case
    /// most likely to be on a poor connection, so there is nothing to gain from fanning this out
    private static let maxConcurrentSwarms: Int = 3

    /// The most sub-requests the storage server will accept in one batch
    ///
    /// `BATCH_REQUEST_MAX` (`request_handler.h:62`). Exceeding it rejects the **whole** batch rather than truncating it, and
    /// both the JSON and bt paths allow exactly this many - the JSON check is `> MAX` while the bt one is `>= MAX` evaluated
    /// before pushing each sub-request, so the two agree despite looking different
    private static let subRequestLimit: Int = 20

    /// How long a successfully-stored hash is barred from being stored again
    ///
    /// **Bounded in time rather than scoped to the session.** A session can outlive the 30-day config TTL - a backgrounded
    /// mobile client, or a desktop client which has no foreground gate and runs for weeks - and in that window a hash barred
    /// after a *successful* store can expire from the swarm a second time. A session-scoped bar then blocks the recovery that
    /// would put it back, and the excluded population is long-lived sessions, which is exactly where configs expire.
    ///
    /// **One hour**, because the bar only ever needed to outlast a burst of polls plus swarm replication lag - polls are
    /// seconds apart and replication is seconds to minutes - while staying far enough under the TTL that it cannot interact
    /// with re-expiry at all. An hour is ~100x the lag it has to cover and 1/720th of the TTL, so both margins are large; it
    /// also bounds the worst case at 24 re-stores per hash per day if a config somehow keeps expiring
    private static let barInterval: TimeInterval = (60 * 60)

    /// How long to defer the next round after a swarm's first failure, doubling per consecutive failure
    private static let baseFailureBackoff: TimeInterval = 60

    /// The longest a retry is ever deferred
    ///
    /// **This bounds the interval, never the attempt count.** Recovery must keep trying indefinitely - a client with no
    /// foreground gate stays open for days, so the growth exists to stop a persistently-failing swarm wasting requests, not
    /// to give up on it. Capping the interval rather than the count is what keeps this a deferral rather than a budget
    private static let maxFailureBackoff: TimeInterval = (30 * 60)

    /// Apply what the latest detection said about a group's keys config to its `expired` flag
    ///
    /// Deliberately **not** deferred behind a recovery attempt. For `GroupInfo`/`GroupMembers` it's right to try re-storing
    /// before flagging anything, so the banner doesn't flicker on every recovery cycle - but a keys config has no recovery
    /// path at all, so there is nothing to wait for and the flag is set straight away.
    ///
    /// This only ever speaks when the device actually held keys hashes to ask about. When it held none, no expire request
    /// was sent, so detection is *structurally silent* rather than reassuring - and the existing "no config messages in the
    /// first poll" check in `GroupPoller.pollerDidStart` remains the authority for that case.
    public static func applyKeysVerdictIfNeeded(
        _ verdict: KeysVerdict,
        swarmPublicKey: String,
        using dependencies: Dependencies
    ) async {
        let expired: Bool

        switch verdict {
            case .noVerdict: return
            case .expired: expired = true
            case .notExpired: expired = false
        }

        do {
            let didChange: Bool = try await dependencies[singleton: .storage].write { db in
                let current: Bool? = try ClosedGroup
                    .filter(id: swarmPublicKey)
                    .select(.expired)
                    .asRequest(of: Bool.self)
                    .fetchOne(db)

                guard current != expired else { return false }

                try ClosedGroup
                    .filter(id: swarmPublicKey)
                    .updateAllAndConfig(
                        db,
                        ClosedGroup.Columns.expired.set(to: expired),
                        using: dependencies
                    )

                return true
            } ?? false

            guard didChange else { return }

            switch expired {
                case true: Log.error(.cat, "Every group keys config message has expired from the swarm for \(swarmPublicKey), flagging the group as expired.")
                case false: Log.info(.cat, "Group keys config messages are present for \(swarmPublicKey), clearing the expired flag.")
            }
        }
        catch {
            Log.error(.cat, "Failed to update the expired flag for \(swarmPublicKey) due to error: \(error).")
        }
    }

    /// Re-store any config messages this swarm has told us it no longer holds
    ///
    /// This is a no-op until the local state is known to be level with the swarm this session - which is what stops a
    /// long-offline device putting back state that has since been deliberately changed. A device that has seen everything the
    /// swarm holds re-stores the current result, which is correct by construction; the dangerous ordering is re-storing while
    /// the swarm still holds config we haven't taken in.
    ///
    /// **Note:** "level with the swarm" is the property, not "a merge happened" - a merge is only *one* way to reach it, and
    /// the case this feature exists for reaches it the other way. A device whose configs have expired gets nothing back from
    /// the swarm to merge, so requiring a literal merge would disable recovery for exactly those devices.
    public static func recoverIfNeeded(
        _ report: DetectionReport,
        swarmPublicKey: String,
        using dependencies: Dependencies
    ) async {
        /// Nothing this poll reported is a candidate, so there is nothing to act on. Detection repeats every poll, so a hash
        /// which is still missing will be reported again - there is no state to carry forward here
        guard !report.recoverableMissingHashes.isEmpty else { return }

        /// Detection runs wherever polling runs, including the background, but acting on it does not - recovery is N extra
        /// store requests and the largest N coincides with the long-offline case most likely to be running in a constrained
        /// background window
        guard dependencies[singleton: .appContext].isAppForegroundAndActive else { return }

        /// Claim the swarm, which also applies the guards which don't need `libSession` (our state is level with the swarm,
        /// we aren't already recovering it, we aren't backing off, and there are hashes we haven't already tried)
        guard
            let candidateHashes: Set<String> = await dependencies[singleton: .configRecovery].beginRecovery(
                swarmPublicKey: swarmPublicKey,
                candidateHashes: report.recoverableMissingHashes,
                maxConcurrentSwarms: maxConcurrentSwarms,
                now: dependencies.dateNow
            )
        else { return }

        /// Hashes whose store **failed** and may therefore be attempted again later, subject to the backoff
        var retryableHashes: Set<String> = []

        /// Hashes actually written this round - any success resets the swarm's backoff growth
        var storedHashes: Set<String> = []

        /// Releasing the claim has to happen on **every** exit from here, and `defer` cannot `await` an actor - so it is
        /// factored into one local closure called at each return rather than duplicated inline. Missing one would leave the
        /// swarm claimed for the rest of the session, which is a silent "recovery stopped working" rather than an error
        let release: (Set<String>, Set<String>) async -> Void = { storedHashes, retryableHashes in
            await dependencies[singleton: .configRecovery].endRecovery(
                swarmPublicKey: swarmPublicKey,
                claimedHashes: candidateHashes,
                storedHashes: storedHashes,
                retryableHashes: retryableHashes,
                now: dependencies.dateNow,
                barInterval: ConfigRecovery.barInterval,
                baseBackoff: ConfigRecovery.baseFailureBackoff,
                maxBackoff: ConfigRecovery.maxFailureBackoff
            )
        }

        /// Apply the remaining guards, all of which need `libSession`: the config must be clean, the hash must still be one
        /// the device believes is current, the group must not be kicked or destroyed, and a keys config can't be re-emitted
        /// at all
        let inspection: LibSession.ConfigRecoveryInspection = dependencies.mutate(cache: .libSession) { cache in
            cache.configRecoveryData(swarmPublicKey: swarmPublicKey, missingHashes: candidateHashes)
        }
        let recoveryData: [LibSession.ConfigRecoveryData] = inspection.data

        /// A config we couldn't inspect has no verdict, so its hashes stay eligible - only a guard actually reaching a
        /// decision settles a hash
        retryableHashes = inspection.inspectionFailedHashes

        /// Anything else ruled out by a guard is barred rather than retried
        guard !recoveryData.isEmpty else {
            await release(storedHashes, retryableHashes)
            return
        }

        do {
            let authMethod: AuthenticationMethod = try Authentication.with(
                swarmPublicKey: swarmPublicKey,
                using: dependencies
            )
            let timestampMs: UInt64 = await dependencies.networkOffsetTimestampMs()

            /// Kept alongside its config so each store's **own** status can be checked afterwards
            ///
            /// The batch itself succeeding says nothing about the stores inside it - a `sequence` returns 200 while its
            /// sub-requests carry their own codes, so treating "didn't throw" as "stored" would bar every hash on a response
            /// where nothing was actually written
            let storeRequests: [(config: LibSession.ConfigRecoveryData, request: any ErasedPreparedRequest)] = try recoveryData
                .flatMap { data -> [(config: LibSession.ConfigRecoveryData, request: any ErasedPreparedRequest)] in
                    try data.data.map { part in
                        (
                            data,
                            try Network.StorageServer.preparedSendMessage(
                                request: Network.StorageServer.SendMessageRequest(
                                    recipient: swarmPublicKey,
                                    namespace: data.variant.namespace,
                                    data: part,
                                    ttl: data.variant.ttl,
                                    timestampMs: timestampMs,
                                    authMethod: authMethod
                                ),
                                using: dependencies
                            )
                        )
                    }
                }
            /// Split into batches the server will actually accept
            ///
            /// The storage server rejects a batch of **more than `subRequestLimit`** sub-requests outright - it does not
            /// truncate - so one oversized sequence loses every store in it, and it surfaces as a request failure rather than a
            /// size error. That matters more than it sounds: a single config can split into ~66 parts (`MAX_MULTIPART_SIZE` /
            /// `MAX_MESSAGE_SIZE`), so **the accounts with the most to lose are exactly the ones whose recovery would be
            /// rejected wholesale**.
            ///
            /// The delete goes in the final batch so every store is applied before it, preserving the ordering that stops a
            /// rejected delete stranding the stores.
            ///
            /// **Note:** Derived from the limit, not from a concurrency cap. A limiter that happens to keep batches small is a
            /// coincidence rather than a bound, and stops being true the moment someone raises it
            let storesPerBatch: Int = ConfigRecovery.subRequestLimit
            let batches: [[(config: LibSession.ConfigRecoveryData, request: any ErasedPreparedRequest)]] = stride(
                from: 0,
                to: max(storeRequests.count, 1),
                by: storesPerBatch
            ).map { start in
                Array(storeRequests[start..<min(start + storesPerBatch, storeRequests.count)])
            }

            /// Accumulated across batches - a batch which fails must leave **its own** configs retryable without condemning
            /// the ones another batch stored successfully
            var failedVariants: Set<ConfigDump.Variant> = []

            for batch in batches {
                let request: Network.PreparedRequest<Network.BatchResponse> = try Network.StorageServer.preparedSequence(
                    requests: batch.map { $0.request },
                    requireAllBatchResponses: false,
                    swarmPublicKey: swarmPublicKey,
                    overallTimeout: Network.defaultTimeout,
                    using: dependencies
                )

                do {
                    let response: Network.BatchResponse = try await request.send(using: dependencies)

                    /// Check each store's own status, not just that the batch came back
                    ///
                    /// A config counts as stored only if **every** one of its parts succeeded - a multipart config isn't
                    /// recovered until all its parts are back - so any part failing leaves the whole config retryable
                    let subResponses: [Any] = Array(response)

                    for (offset, element) in batch.enumerated() {
                        let subResponse: ErasedBatchSubResponse? = (
                            subResponses.count > offset ?
                                (subResponses[offset] as? ErasedBatchSubResponse) :
                                nil
                        )

                        guard
                            let subResponse: ErasedBatchSubResponse = subResponse,
                            200...299 ~= subResponse.code,
                            !subResponse.failedToParseBody
                        else {
                            failedVariants.insert(element.config.variant)
                            continue
                        }
                    }
                }
                catch {
                    /// Only this batch's configs are affected - the others may well have landed
                    failedVariants.formUnion(batch.map { $0.config.variant })
                    Log.error(.cat, "A recovery batch failed for \(swarmPublicKey) due to error: \(error).")
                }
            }

            let landedRestores: [LibSession.ConfigRecoveryData] = recoveryData
                .filter { !failedVariants.contains($0.variant) }
            storedHashes = landedRestores.reduce(into: []) { $0.formUnion($1.missingHashes) }

            /// Delete the superseded hashes **only for restores that fully landed**, and only after the stores have run
            ///
            /// The obsolete hashes are the ones our own config superseded, and `push()` cleared `libSession`'s copy of them, so
            /// they have to be swept here or they linger. But a restore that did *not* land leaves the swarm still holding the
            /// state those hashes belong to, and deleting them then would remove data with nothing put back in its place.
            ///
            /// **Note:** No cross-round state is needed - the hashes are still in memory within this round. Deletes go last so
            /// every store is applied first, and they count against the same chunk budget
            let hashesToSweep: Set<String> = landedRestores.reduce(into: []) { $0.formUnion($1.obsoleteHashes) }

            if !hashesToSweep.isEmpty {
                do {
                    let deleteRequest: Network.PreparedRequest<[String: Bool]> = try Network.StorageServer
                        .preparedDeleteMessages(
                            serverHashes: Array(hashesToSweep),
                            requireSuccessfulDeletion: false,
                            handlePotentialDeletedOrInvalidHash: SnodeReceivedMessageInfo
                                .handlePotentialDeletedOrInvalidHash(potentiallyInvalidHashes:using:),
                            authMethod: authMethod,
                            using: dependencies
                        )
                    let _: [String: Bool] = try await deleteRequest.send(using: dependencies)
                }
                catch {
                    /// A failed sweep doesn't affect what was stored - the obsolete messages simply linger until their TTL,
                    /// which is the pre-existing behaviour rather than a regression
                    Log.warn(.cat, "Failed to delete \(hashesToSweep.count) superseded config hash(es) for \(swarmPublicKey) due to error: \(error).")
                }
            }

            /// Anything whose store didn't land stays eligible for a later attempt rather than spending it
            let failedHashes: Set<String> = recoveryData
                .filter { failedVariants.contains($0.variant) }
                .reduce(into: Set<String>()) { $0.formUnion($1.missingHashes) }
            retryableHashes.formUnion(failedHashes)

            switch retryableHashes.isEmpty {
                case true:
                    Log.info(.cat, "Re-stored \(recoveryData.count) expired config(s) for \(swarmPublicKey) (\(storedHashes.count) hash(es)).")

                case false:
                    Log.warn(.cat, "Re-stored \(storedHashes.count) of \(storedHashes.count + retryableHashes.count) expired config hash(es) for \(swarmPublicKey); the rest will be retried.")
            }
        }
        catch {
            /// Reached only if something *before* the batches threw - building the requests, or resolving auth. Each batch
            /// handles its own failure inline so one batch cannot condemn another's hashes.
            ///
            /// A failed store is **not** an attempt spent - these stay eligible so a later poll can try again once the
            /// per-swarm backoff has elapsed. Barring them here would withdraw recovery for a whole bar interval over a blip
            retryableHashes.formUnion(
                recoveryData.reduce(into: Set<String>()) { $0.formUnion($1.missingHashes) }
            )

            Log.error(.cat, "Failed to re-store expired config(s) for \(swarmPublicKey) due to error: \(error).")
        }

        await release(storedHashes, retryableHashes)
    }
}

// MARK: - Singleton

public extension Singleton {
    static let configRecovery: SingletonConfig<ConfigRecoveryStoreType> = Dependencies.create(
        identifier: "configRecovery",
        createInstance: { _, _ in ConfigRecovery.Store() }
    )
}

public extension ConfigRecovery {
    /// The cross-poll bookkeeping config recovery needs: which swarms are level, which are mid-recovery, which hashes are
    /// barred, and how far each swarm's next retry is deferred
    ///
    /// **An `actor` rather than a lock-guarded cache**, so the concurrency protection is the language's rather than
    /// hand-rolled. Everything a *single* poll discovers is passed as a parameter instead (see `DetectionReport`) - what
    /// remains here is only state that genuinely has to outlive one poll.
    ///
    /// Deliberately not persisted. The barred-hash entries are time-bounded so they expire on their own, and everything else
    /// describes this process's view of the swarm, which a relaunch should re-establish rather than inherit
    actor Store: ConfigRecoveryStoreType {
        /// When each hash stops being barred from another store attempt
        ///
        /// **Time-bounded, not session-scoped.** A session can outlive the 30-day TTL, and in that window a hash barred after a
        /// successful store can expire again - a session-scoped bar would block the recovery that would put it back.
        ///
        /// **Note:** Not keyed by swarm - the storage server derives a message hash from the pubkey, namespace and
        /// ciphertext, so the same hash can't belong to two swarms
        private var barredUntil: [String: Date] = [:]

        /// Swarms whose contents we have fully taken in at some point this session
        private var swarmsLevelWithLocalState: Set<String> = []

        /// Swarms where we are known to have **failed** to take a config message in
        ///
        /// **This is sticky for the session, and it has to be.** A config message which parses but fails to merge has already
        /// had its `lastHash` advanced past it (that happens at parse time, before the merge), so the next poll won't return
        /// it - and a poll that returns no config messages is otherwise read as "we're level with the swarm". Without this,
        /// a lossy merge is corrected for exactly one poll and then silently becomes indistinguishable from a clean one
        private var swarmsWithIncompleteMerge: Set<String> = []

        /// Swarms with a recovery attempt in flight
        private var inProgress: Set<String> = []

        /// When each swarm may next be attempted, after a failure
        private var nextAttempt: [String: Date] = [:]

        /// Consecutive failed rounds per swarm, which sets how far the next retry is deferred
        private var consecutiveFailures: [String: Int] = [:]

        // MARK: - Functions

        public func markLocalStateLevelWithSwarm(swarmPublicKey: String) {
            swarmsLevelWithLocalState.insert(swarmPublicKey)
        }

        public func markMergeIncompleteForSwarm(swarmPublicKey: String) {
            swarmsWithIncompleteMerge.insert(swarmPublicKey)
            Log.warn(.cat, "Failed to take in every config message for \(swarmPublicKey), so its local state can't be treated as level with the swarm for the rest of this session.")
        }

        public func localStateIsLevelWithSwarm(swarmPublicKey: String) -> Bool {
            /// A known-lossy merge disqualifies the swarm outright, however many clean polls follow it - the message we failed
            /// to take in is unreachable now, so a later quiet poll is not evidence we caught up
            return (
                swarmsLevelWithLocalState.contains(swarmPublicKey) &&
                !swarmsWithIncompleteMerge.contains(swarmPublicKey)
            )
        }

        public func hashesEligibleForRecovery(_ hashes: Set<String>, now: Date) -> Set<String> {
            return hashes.filter { hash in
                guard let barredUntil: Date = barredUntil[hash] else { return true }

                return (now >= barredUntil)
            }
        }

        public func beginRecovery(
            swarmPublicKey: String,
            candidateHashes: Set<String>,
            maxConcurrentSwarms: Int,
            now: Date
        ) -> Set<String>? {
            /// Our local state must be known to be level with this swarm - this is what prevents a long-offline device from
            /// re-storing state which has since been deliberately changed
            guard localStateIsLevelWithSwarm(swarmPublicKey: swarmPublicKey) else { return nil }
            guard !inProgress.contains(swarmPublicKey) else { return nil }
            guard inProgress.count < maxConcurrentSwarms else { return nil }

            if let nextAttempt: Date = nextAttempt[swarmPublicKey], now < nextAttempt { return nil }

            let eligibleHashes: Set<String> = hashesEligibleForRecovery(candidateHashes, now: now)

            guard !eligibleHashes.isEmpty else { return nil }

            inProgress.insert(swarmPublicKey)

            return eligibleHashes
        }

        public func endRecovery(
            swarmPublicKey: String,
            claimedHashes: Set<String>,
            storedHashes: Set<String>,
            retryableHashes: Set<String>,
            now: Date,
            barInterval: TimeInterval,
            baseBackoff: TimeInterval,
            maxBackoff: TimeInterval
        ) {
            inProgress.remove(swarmPublicKey)

            /// A hash is barred **for `barInterval`** once it has been successfully stored, or once a guard has ruled it out.
            /// It is *not* barred by a store which failed - that is the one distinction here.
            ///
            /// Two properties, and it is worth being exact about which is which:
            ///
            /// - **Bounded, not permanent.** The bar stops repeated *detections* causing a re-push storm, which only ever
            ///   required outlasting a burst of polls. Making it last a whole session made it unbounded in time while the TTL
            ///   is not, so a hash could expire again behind its own bar - see `barInterval`.
            /// - **Success and guard rejections only.** A store which failed is not a re-store, so barring it would withdraw
            ///   recovery from a device with a genuinely expired config on the strength of one network blip. Retries are
            ///   bounded by the per-swarm backoff instead.
            ///
            /// Guard rejections are barred on the **same clock**, and that is not merely for symmetry: "nothing will change
            /// within the session" is the same session-scoped assumption the time-bound exists to correct. Over weeks a kicked
            /// group can be rejoined, a destroyed one replaced, and a dirty config settles and becomes clean. Re-examining a
            /// rejection is free - the guards reject before any network call - so there was never a cost justifying permanence
            claimedHashes.subtracting(retryableHashes).forEach { hash in
                barredUntil[hash] = now.addingTimeInterval(barInterval)
            }

            /// Drop entries whose bar has lapsed, so the map cannot grow without bound across a long session
            ///
            /// It would otherwise accumulate one entry per hash ever settled, and the hashes **rotate** - a re-pushed config
            /// occupies new ones - so this is genuine growth rather than the same keys being overwritten
            barredUntil = barredUntil.filter { _, expiry in expiry > now }

            /// Defer the next round when something is left to retry, doubling per consecutive failure up to the ceiling
            ///
            /// **The growth is a deferral, not a cap** - the interval is bounded, the number of attempts never is. Any
            /// successful store resets it, which can't loop indefinitely because a stored hash is barred for `barInterval`
            /// afterwards, so a success cannot immediately re-arm the reset it just caused
            guard !retryableHashes.isEmpty else {
                consecutiveFailures.removeValue(forKey: swarmPublicKey)
                nextAttempt.removeValue(forKey: swarmPublicKey)
                return
            }

            switch storedHashes.isEmpty {
                case false: consecutiveFailures[swarmPublicKey] = 1
                case true: consecutiveFailures[swarmPublicKey] = ((consecutiveFailures[swarmPublicKey] ?? 0) + 1)
            }

            /// Double per consecutive failure, holding at the ceiling rather than ever running out - the interval is capped,
            /// the attempt count never is, which is what keeps this a deferral rather than a budget
            let failures: Int = (consecutiveFailures[swarmPublicKey] ?? 1)
            let interval: TimeInterval = min(
                baseBackoff * pow(2, TimeInterval(failures - 1)),
                maxBackoff
            )
            nextAttempt[swarmPublicKey] = now.addingTimeInterval(interval)
        }
    }
}

// MARK: - ConfigRecoveryStoreType

/// **Note:** No immutable/mutable split - that pairing exists to stop unsynchronised mutation of a lock-guarded cache, and an
/// actor enforces the same thing at the language level
public protocol ConfigRecoveryStoreType: Actor {
    /// Whether our local state is known to be level with the given swarm
    func localStateIsLevelWithSwarm(swarmPublicKey: String) -> Bool

    /// Filters `hashes` down to those not currently barred
    func hashesEligibleForRecovery(_ hashes: Set<String>, now: Date) -> Set<String>

    /// Record that our local state for the given swarm is level with what the swarm holds
    func markLocalStateLevelWithSwarm(swarmPublicKey: String)

    /// Record that we failed to take in a config message for the given swarm
    ///
    /// Sticky for the session - the message is unreachable after this, so no later poll can establish that we caught up
    func markMergeIncompleteForSwarm(swarmPublicKey: String)

    /// Claim the swarm for a recovery attempt, returning the hashes to attempt (or `nil` if a guard says not to)
    func beginRecovery(
        swarmPublicKey: String,
        candidateHashes: Set<String>,
        maxConcurrentSwarms: Int,
        now: Date
    ) -> Set<String>?

    /// Release the swarm after a recovery attempt
    ///
    /// Everything in `claimedHashes` is barred for `barInterval` **except** `retryableHashes`, which are the ones whose store
    /// failed and so may be attempted again once the backoff has elapsed
    func endRecovery(
        swarmPublicKey: String,
        claimedHashes: Set<String>,
        storedHashes: Set<String>,
        retryableHashes: Set<String>,
        now: Date,
        barInterval: TimeInterval,
        baseBackoff: TimeInterval,
        maxBackoff: TimeInterval
    )
}
