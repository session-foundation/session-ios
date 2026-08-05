// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import SessionUtilitiesKit

// MARK: - ConfigExpiryDetection

public extension Network.StorageServer {
    /// The outcome of inspecting an `expire` response to work out whether any of the config messages we asked it to
    /// extend have already been swept from the swarm
    ///
    /// The `expire` endpoint is recursive - one service node fans the request out to the whole swarm and returns a
    /// `swarm` dict keyed by service node pubkey, where each entry reports the hashes it `updated` and the hashes it
    /// still holds but left `unchanged`. A hash in **neither** array means that node's database has no such message
    /// for this account
    ///
    /// This is deliberately a standalone value type rather than logic buried in the poller so it can be tested directly
    /// against the shared cross-client test vectors
    enum ConfigExpiryDetection: Equatable {
        /// Detection wasn't possible for this response, so nothing may be inferred
        ///
        /// Either the request didn't set `extend` or no eligible sub-response included the `unchanged` key. In both
        /// cases the server omits `unchanged`, which makes every hash it didn't happen to update look missing
        case unavailable

        /// Every sub-response failed, so there is no evidence either way
        ///
        /// This is distinct from "nothing is missing" - a swarm we couldn't reach tells us nothing about what it holds
        case inconclusive

        /// At least one sub-response was eligible
        ///
        /// `missingHashes` are the requested hashes which at least one eligible service node reported it doesn't hold
        case checked(missingHashes: Set<String>)

        /// The hashes which have expired from the swarm (always empty unless the result was `checked`)
        public var missingHashes: Set<String> {
            switch self {
                case .unavailable, .inconclusive: return []
                case .checked(let missingHashes): return missingHashes
            }
        }
    }
}

// MARK: - Detection

public extension Network.StorageServer.ConfigExpiryDetection {
    /// Work out which of `requestedHashes` have expired from the swarm
    ///
    /// - Parameters:
    ///   - requestedHashes: The hashes the `expire` request asked about
    ///   - extendWasRequested: Whether the request set `extend: true`
    ///   - resultMap: The per-service-node results, as produced by `UpdateExpiryResponse.validResultMap`
    static func detect(
        requestedHashes: [String],
        extendWasRequested: Bool,
        resultMap: [String: Network.StorageServer.UpdateExpiryResponseResult]
    ) -> Self {
        /// Detection must not run on a response to a request which didn't set `extend: true`
        ///
        /// Without it the server omits `unchanged` entirely, so every hash which wasn't updated would look missing.
        /// This bites hardest for a group *member*, who authenticates with a subaccount lacking `Delete` - the server
        /// silently forces extend-only semantics on the update while still omitting `unchanged`, so healthy hashes
        /// would land in neither array on every single poll
        guard extendWasRequested else { return .unavailable }

        /// Asking about nothing answers nothing
        ///
        /// A device holding no hashes for a swarm doesn't send an expire sub-request at all, so detection is *structurally
        /// silent* for it - which must not be reported as a conclusive "nothing is missing". That case is covered by the
        /// separate check for a swarm which returns no config messages at all, and this must not pre-empt it
        guard !requestedHashes.isEmpty else { return .inconclusive }

        /// A sub-response is eligible only if it didn't fail **and** it actually told us what it still holds
        ///
        /// An ineligible sub-response contributes nothing - it is neither evidence of presence nor of absence. Failed
        /// entries may also carry `timeout`, `code`, `reason`, `bad_peer_response` or `query_failure` but none of that
        /// matters; the presence of `failed` is enough to exclude it. Treating a timeout as "that node doesn't have it"
        /// would turn every network blip into a re-push storm
        let eligibleResults: [Network.StorageServer.UpdateExpiryResponseResult] = resultMap.values
            .filter { !$0.didError && $0.hasUnchangedInfo }

        /// If no sub-response is eligible then we can't conclude anything - no hash may be marked missing and no
        /// recovery may be triggered
        guard !eligibleResults.isEmpty else {
            /// Distinguish "we couldn't reach anyone" from "the responses we got can't answer the question"; both are
            /// equally non-actionable but they mean different things when reading logs
            return (
                resultMap.values.contains(where: { !$0.didError }) ?
                    .unavailable :
                    .inconclusive
            )
        }

        /// A hash is missing if it is absent from both `updated` and `unchanged` in at least **one** eligible
        /// sub-response - presence in the others does not override that
        ///
        /// One node reporting absence is enough on purpose: re-storing is idempotent so a false positive costs a
        /// redundant store, whereas waiting for consensus would lean on the swarm replication which is itself the
        /// unreliable part
        return .checked(
            missingHashes: Set(requestedHashes).filter { hash in
                eligibleResults.contains { result in
                    result.changed[hash] == nil && result.unchanged[hash] == nil
                }
            }
        )
    }
}
