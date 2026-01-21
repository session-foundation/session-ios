// Copyright © 2026 Rangeproof Pty Ltd. All rights reserved.

import Foundation
import GRDB
import SessionUtilitiesKit

public enum FileJobDataSorter: JobSorterDataRetriever {
    public static func retrieveData(_ jobStates: [JobState], using dependencies: Dependencies) async -> Any? {
        /// Extract the relevant data from the jobs
        var jobIdToAttachmentId: [JobQueue.JobQueueId: String] = [:]
        var displayPictureAuthorIds: Set<String> = []
        
        jobStates.forEach { jobState in
            guard let detailsData: Data = jobState.job.details else { return }
            
            switch jobState.job.variant {
                case .attachmentDownload:
                    guard
                        let jobId: Int64 = jobState.job.id,
                        let details: AttachmentDownloadJob.Details = try? JSONDecoder(using: dependencies)
                            .decode(AttachmentDownloadJob.Details.self, from: detailsData)
                    else { return }
                    
                    jobIdToAttachmentId[jobState.queueId] = details.attachmentId
                    
                case .displayPictureDownload:
                    guard
                        let jobId: Int64 = jobState.job.id,
                        let details: DisplayPictureDownloadJob.Details = try? JSONDecoder(using: dependencies)
                        .decode(DisplayPictureDownloadJob.Details.self, from: detailsData),
                        case .profile(let id, _, _) = details.target
                    else { return }
                    
                    displayPictureAuthorIds.insert(id)
                    
                default: break
            }
        }
        
        /// Fetch the data required for sorting from the database
        let thread: TypedTableAlias<SessionThread> = TypedTableAlias()
        let groupMember: TypedTableAlias<GroupMember> = TypedTableAlias()
        let interaction: TypedTableAlias<Interaction> = TypedTableAlias()
        let interactionAttachment: TypedTableAlias<InteractionAttachment> = TypedTableAlias()
        var attachmentTimestamps: Set<FetchablePair<String, Int64>> = []
        var profileTimestamps: Set<FetchablePair<String, Int64>> = []
        var visibleContactThreadIds: Set<String> = []
        var groupIdToMemberId: Set<FetchablePair<String, String>> = []
        
        try? await dependencies[singleton: .storage].readAsync { db in
            attachmentTimestamps = try SQLRequest<FetchablePair<String, Int64>>("""
                SELECT
                    \(interactionAttachment[.attachmentId]),
                    \(interaction[.timestampMs])
                FROM \(interactionAttachment)
                JOIN \(interaction) ON \(interaction[.id]) = \(interactionAttachment[.interactionId])
                WHERE \(interactionAttachment[.attachmentId]) IN \(Set(jobIdToAttachmentId.values))
            """).fetchSet(db)
            profileTimestamps = try SQLRequest<FetchablePair<String, Int64>>("""
                SELECT
                    \(interaction[.authorId]),
                    MAX(\(interaction[.timestampMs]))
                FROM \(interaction)
                WHERE \(interaction[.authorId]) IN \(displayPictureAuthorIds)
                GROUP BY \(interaction[.authorId])
            """).fetchSet(db)
            
            visibleContactThreadIds = try SQLRequest<String>("""
                SELECT \(thread[.id])
                FROM \(thread)
                WHERE \(thread[.shouldBeVisible]) = TRUE
            """).fetchSet(db)
            groupIdToMemberId = try SQLRequest<FetchablePair<String, String>>("""
                SELECT
                    \(groupMember[.groupId]),
                    \(groupMember[.profileId])
                FROM \(groupMember)
            """).fetchSet(db)
        }
        
        /// Convert fetched data into dicts
        let userSessionId: SessionId = dependencies[cache: .general].sessionId
        let attachmentIdToTimestampMs: [String: Int64] = attachmentTimestamps.reduce(into: [:]) { result, next in
            result[next.first] = next.second
        }
        let profileIdsToLastMessageTimestampMs: [String: Int64] = profileTimestamps.reduce(into: [:]) { result, next in
            result[next.first] = next.second
        }
        let profileIdsInConversationList: Set<String> = visibleContactThreadIds
            .inserting(
                contentsOf: Set(groupIdToMemberId
                    .grouped(by: \.first)
                    .flatMap { _, values -> [String] in
                        let memberIds: Set<String> = Set(values.map(\.second))
                        let sortedIds: [String] = memberIds
                            .filter { $0 != userSessionId.hexString }
                            .sorted()
                        
                        guard !memberIds.isEmpty else { return [] }
                        guard let firstId: String = sortedIds.first else { return [userSessionId.hexString] }
                        
                        guard
                            sortedIds.count > 1,
                            let secondId: String = sortedIds.last,
                            secondId != firstId
                        else { return [firstId] }
                        
                        return [firstId, secondId]
                    })
            )
        let jobIdToThreadId: [JobQueue.JobQueueId: String] = jobStates.reduce(into: [:]) { result, next in
            switch next.job.variant {
                case .displayPictureDownload:
                    guard
                        let detailsData: Data = next.job.details,
                        let details: DisplayPictureDownloadJob.Details = try? JSONDecoder(using: dependencies)
                            .decode(DisplayPictureDownloadJob.Details.self, from: detailsData)
                    else { return }
                    
                    switch details.target {
                        case .profile(let id, _, _): result[next.queueId] = id
                        case .group(let id, _, _): result[next.queueId] = id
                        case .community(_, let roomToken, let server, _):
                            result[next.queueId] = OpenGroup.idFor(roomToken: roomToken, server: server)
                    }
                    
                default:
                    guard let threadId: String = next.job.threadId else { return }
                    
                    result[next.queueId] = threadId
                    
            }
        }
        let jobIdToProfileId: [JobQueue.JobQueueId: String] = jobStates.reduce(into: [:]) { result, next in
            guard
                next.job.variant == .displayPictureDownload,
                let detailsData: Data = next.job.details,
                let details: DisplayPictureDownloadJob.Details = try? JSONDecoder(using: dependencies)
                    .decode(DisplayPictureDownloadJob.Details.self, from: detailsData),
                case .profile(let profileId, _, _) = details.target
            else { return }
            
            result[next.queueId] = profileId
        }
        let displayPictureJobIdsUpdatingConversationList: Set<JobQueue.JobQueueId> = Set(jobStates.compactMap { jobState in
            guard
                jobState.job.variant == .displayPictureDownload,
                let detailsData: Data = jobState.job.details,
                let details: DisplayPictureDownloadJob.Details = try? JSONDecoder(using: dependencies)
                    .decode(DisplayPictureDownloadJob.Details.self, from: detailsData)
            else { return nil }
            
            switch details.target {
                case .group, .community: return jobState.queueId
                case .profile(let id, _, _):
                    guard profileIdsInConversationList.contains(id) else { return nil }
                    
                    return jobState.queueId
            }
        })
        
        return JobQueue.JobSorter.FileSortData(
            jobIdToAttachmentId: jobIdToAttachmentId,
            attachmentIdToTimestampMs: attachmentIdToTimestampMs,
            jobIdToProfileId: jobIdToProfileId,
            profileIdsToLastMessageTimestampMs: profileIdsToLastMessageTimestampMs,
            profileIdsInConversationList: profileIdsInConversationList,
            jobIdToThreadId: jobIdToThreadId,
            displayPictureJobIdsUpdatingConversationList: displayPictureJobIdsUpdatingConversationList
        )
    }
}
