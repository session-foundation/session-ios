// Copyright © 2023 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import Combine
import GRDB
import SessionUtil
import SessionUIKit
import SessionUtilitiesKit
import SessionNetworkingKit

// MARK: - Log.Category

private extension Log.Category {
    static let cat: Log.Category = .create("ProcessPendingGroupMemberRemovalsJob", defaultLevel: .info)
}

// MARK: - ProcessPendingGroupMemberRemovalsJob

public enum ProcessPendingGroupMemberRemovalsJob: JobExecutor {
    public static var maxFailureCount: Int = 1
    public static var requiresThreadId: Bool = true
    public static var requiresInteractionId: Bool = false
    private static let maxRunFrequency: TimeInterval = 3
    
    public static func canStart(
        jobState: JobState,
        alongside runningJobs: [JobState],
        using dependencies: Dependencies
    ) -> Bool {
        return true
    }
    
    public static func run(_ job: Job, using dependencies: Dependencies) async throws -> JobExecutionResult {
        guard
            let groupSessionId: SessionId = job.threadId.map({ SessionId(.group, hex: $0) }),
            let detailsData: Data = job.details,
            let details: Details = try? JSONDecoder(using: dependencies).decode(Details.self, from: detailsData)
        else { throw JobRunnerError.missingRequiredDetails }
        
        let groupIdentityPrivateKey: Data = try dependencies
            .mutate(cache: .libSession) { $0.authData(groupSessionId: groupSessionId) }
            .groupIdentityPrivateKey ?? {
                throw JobRunnerError.missingRequiredDetails
            }()
        try Task.checkCancellation()
        
        /// It's possible for multiple jobs with the same target (group) to try to run at the same time, rather than adding dependencies
        /// between the jobs we just continue to defer the subsequent job while the first one is running in order to prevent multiple jobs
        /// with the same target from running at the same time
        let maybeExistingJobState: JobState? = await dependencies[singleton: .jobRunner].firstJobMatching(
            filters: JobRunner.Filters(
                include: [
                    .variant(.processPendingGroupMemberRemovals),
                    .executionPhase(.running)
                ],
                exclude: [
                    job.id.map { .jobId($0) },          /// Exclude this job
                    job.threadId.map { .threadId($0) }  /// Exclude jobs for different conversations
                ].compactMap { $0 }
            )
        )
        try Task.checkCancellation()
        
        if let existingJobState: JobState = maybeExistingJobState {
            /// Wait for the existing job to complete before continuing
            Log.info(.cat, "For \(job.threadId ?? "UnknownId") waiting for completion of in-progress job")
            _ = try? await dependencies[singleton: .jobRunner].finalResult(for: existingJobState.job)
            try Task.checkCancellation()
            
            /// Also want to wait for `maxRunFrequency` to throttle the config sync runs
            try? await Task.sleep(for: .seconds(Int(maxRunFrequency)))
            try Task.checkCancellation()
        }
        
        /// If there are no pending removals then we can just complete
        guard
            let pendingRemovals: [String: GROUP_MEMBER_STATUS] = try? LibSession.getPendingMemberRemovals(
                groupSessionId: groupSessionId,
                using: dependencies
            ),
            !pendingRemovals.isEmpty
        else {
            return .success
        }
        
        /// Define a timestamp to use for all messages created by the removal changes
        ///
        /// **Note:** The `targetChangeTimestampMs` will differ from the `messageSendTimestamp` as it's the time the
        /// member was originally removed whereas the `messageSendTimestamp` is the time it will be uploaded to the swarm
        let targetChangeTimestampMs: Int64 = (
            details.changeTimestampMs ??
            dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        )
        let messageSendTimestamp: Int64 = dependencies[cache: .snodeAPI].currentOffsetTimestampMs()
        let memberIdsToRemoveContent: Set<String> = pendingRemovals
            .filter { _, status -> Bool in status == GROUP_MEMBER_STATUS_REMOVED_MEMBER_AND_MESSAGES }
            .map { memberId, _ -> String in memberId }
            .asSet()
        
        /// Revoke the members authData from the group so the server rejects API calls from the ex-members (fire-and-forget
        /// this request, we don't want it to be blocking)
        let preparedRevokeSubaccounts: Network.PreparedRequest<Void> = try Network.SnodeAPI.preparedRevokeSubaccounts(
            subaccountsToRevoke: try dependencies.mutate(cache: .libSession) { cache in
                try Array(pendingRemovals.keys).map { memberId in
                    try dependencies[singleton: .crypto].tryGenerate(
                        .tokenSubaccount(
                            config: cache.config(for: .groupKeys, sessionId: groupSessionId),
                            groupSessionId: groupSessionId,
                            memberId: memberId
                        )
                    )
                }
            },
            authMethod: Authentication.groupAdmin(
                groupSessionId: groupSessionId,
                ed25519SecretKey: Array(groupIdentityPrivateKey)
            ),
            using: dependencies
        )
        
        /// Prepare a `groupKicked` `LibSessionMessage` to be sent (instruct their clients to delete the group content)
        let currentGen: Int = try LibSession.currentGeneration(
            groupSessionId: groupSessionId,
            using: dependencies
        )
        let deleteMessageData: [(recipient: SessionId, message: Data)] = pendingRemovals.keys
            .compactMap { try? LibSessionMessage.groupKicked(memberId: $0, groupKeysGen: currentGen) }
        let encryptedDeleteMessageData: Data = try dependencies[singleton: .crypto].tryGenerate(
            .ciphertextWithMultiEncrypt(
                messages: deleteMessageData.map { $0.message },
                toRecipients: deleteMessageData.map { $0.recipient },
                ed25519PrivateKey: Array(groupIdentityPrivateKey),
                domain: .kickedMessage
            )
        )
        let preparedGroupDeleteMessage: Network.PreparedRequest<Void> = try Network.SnodeAPI
            .preparedSendMessage(
                message: SnodeMessage(
                    recipient: groupSessionId.hexString,
                    data: encryptedDeleteMessageData,
                    ttl: Message().ttl,
                    timestampMs: UInt64(messageSendTimestamp)
                ),
                in: .revokedRetrievableGroupMessages,
                authMethod: Authentication.groupAdmin(
                    groupSessionId: groupSessionId,
                    ed25519SecretKey: Array(groupIdentityPrivateKey)
                ),
                using: dependencies
            )
            .map { _, _ in () }
        
        /// If we want to remove the messages sent by the removed members then also send an instruction
        /// to other members to remove the messages as well
        let preparedMemberContentRemovalMessage: Network.PreparedRequest<Void>? = { () -> Network.PreparedRequest<Void>? in
            guard !memberIdsToRemoveContent.isEmpty else { return nil }
            
            return try? MessageSender.preparedSend(
                message: GroupUpdateDeleteMemberContentMessage(
                    memberSessionIds: Array(memberIdsToRemoveContent),
                    messageHashes: [],
                    sentTimestampMs: UInt64(targetChangeTimestampMs),
                    authMethod: Authentication.groupAdmin(
                        groupSessionId: groupSessionId,
                        ed25519SecretKey: Array(groupIdentityPrivateKey)
                    ),
                    using: dependencies
                ),
                to: .group(publicKey: groupSessionId.hexString),
                namespace: .groupMessages,
                interactionId: nil,
                attachments: nil,
                authMethod: Authentication.groupAdmin(
                    groupSessionId: groupSessionId,
                    ed25519SecretKey: Array(groupIdentityPrivateKey)
                ),
                onEvent: MessageSender.standardEventHandling(using: dependencies),
                using: dependencies
            )
            .map { _, _ in () }
        }()
        
        /// Combine the two requests to be sent at the same time
        let request = try Network.SnodeAPI.preparedSequence(
            requests: [preparedRevokeSubaccounts, preparedGroupDeleteMessage, preparedMemberContentRemovalMessage]
                .compactMap { $0 },
            requireAllBatchResponses: true,
            swarmPublicKey: groupSessionId.hexString,
            snodeRetrievalRetryCount: 0, // Job has a built-in retry
            using: dependencies
        )
        
        // FIXME: Refactor to async/await
        let response = try await request.send(using: dependencies)
            .values
            .first { _ in true }?.1 ?? { throw NetworkError.invalidResponse }()
        try Task.checkCancellation()
        
        /// If any one of the requests failed then we didn't successfully remove the members access so try again later
        guard
            response.allSatisfy({ subResponse in
                200...299 ~= ((subResponse as? Network.BatchSubResponse<Void>)?.code ?? 400)
            })
        else { throw MessageError.invalidGroupUpdate("Failed to remove group member") }
        
        let hashes: Set<String> = try await dependencies[singleton: .storage].writeAsync { db in
            /// Remove the members from the `GROUP_MEMBERS` config
            try LibSession.removeMembers(
                db,
                groupSessionId: groupSessionId,
                memberIds: Set(pendingRemovals.keys),
                using: dependencies
            )
            
            /// We need to update the group keys when removing members so they can't decrypt any
            /// more group messages
            ///
            /// **Note:** This **MUST** be called _after_ the members have been removed, otherwise
            /// the removed members may still be able to access the keys
            try LibSession.rekey(
                db,
                groupSessionId: groupSessionId,
                using: dependencies
            )
            
            /// Remove the members from the database
            try GroupMember
                .filter(GroupMember.Columns.groupId == groupSessionId.hexString)
                .filter(pendingRemovals.keys.contains(GroupMember.Columns.profileId))
                .deleteAll(db)
            
            pendingRemovals.keys.forEach { id in
                db.addGroupMemberEvent(
                    profileId: id,
                    threadId: groupSessionId.hexString,
                    type: .deleted
                )
            }
            
            /// If we want to remove the messages sent by the removed members then do so and remove
            /// them from the swarm as well
            if !memberIdsToRemoveContent.isEmpty {
                let interactionIdsToRemove: Set<Int64> = try Interaction
                    .select(.id)
                    .filter(Interaction.Columns.threadId == groupSessionId.hexString)
                    .filter(memberIdsToRemoveContent.contains(Interaction.Columns.authorId))
                    .asRequest(of: Int64.self)
                    .fetchSet(db)
                
                /// Retrieve the hashes which should be deleted first (these will be removed from the local
                /// device in the `markAsDeleted` function) then call `markAsDeleted` to remove
                /// message content
                let hashes: Set<String> = try Interaction.serverHashesForDeletion(
                    db,
                    interactionIds: interactionIdsToRemove
                )
                try Interaction.markAsDeleted(
                    db,
                    threadId: groupSessionId.hexString,
                    threadVariant: .group,
                    interactionIds: interactionIdsToRemove,
                    options: [.local, .network],
                    using: dependencies
                )
                
                return hashes
            }
            
            return []
        }
        try Task.checkCancellation()
            
        /// Delete the messages from the swarm so users won't download them again
        if !hashes.isEmpty {
            Task.detached(priority: .medium) {
                let request = try? Network.SnodeAPI.preparedDeleteMessages(
                    serverHashes: Array(hashes),
                    requireSuccessfulDeletion: false,
                    authMethod: Authentication.groupAdmin(
                        groupSessionId: groupSessionId,
                        ed25519SecretKey: Array(groupIdentityPrivateKey)
                    ),
                    using: dependencies
                )
                // FIXME: Refactor to async/await
                _ = try? await request.send(using: dependencies)
                    .values
                    .first { _ in true }
            }
        }
        
        return .success
    }
}

// MARK: - ProcessPendingGroupMemberRemovalsJob.Details

extension ProcessPendingGroupMemberRemovalsJob {
    public struct Details: Codable {
        public let changeTimestampMs: Int64?
        
        public init(changeTimestampMs: Int64? = nil) {
            self.changeTimestampMs = changeTimestampMs
        }
    }
}
